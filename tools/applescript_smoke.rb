#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require 'securerandom'
require 'timeout'
require 'tmpdir'

root = File.expand_path('..', __dir__)
source = File.join(root, 'dist', 'Terminal.app')
abort "Missing built app: #{source}" unless File.executable?(File.join(source, 'Contents/MacOS/Terminal'))

fixture_root = Dir.mktmpdir('helge-terminal-applescript-')
fixture = File.join(fixture_root, 'Terminal Automation Fixture.app')
bundle_id = "no.helgesverre.terminal.automation-fixture.#{SecureRandom.hex(6)}"
child_pids_path = File.join(fixture_root, 'children.pids')
report_path = File.join(root, 'reports', 'applescript-smoke.json')
app_pid = nil
child_pids = []

def applescript_literal(value)
  '"' + value.gsub('\\', '\\\\').gsub('"', '\\"') + '"'
end

def terminate_command(wait_thread)
  return wait_thread.value if wait_thread.join(0)

  begin
    Process.kill('TERM', wait_thread.pid)
  rescue Errno::ESRCH
    return wait_thread.value
  end
  begin
    Timeout.timeout(1) { return wait_thread.value }
  rescue Timeout::Error
    begin Process.kill('KILL', wait_thread.pid); rescue Errno::ESRCH; end
    return wait_thread.value
  end
end

def capture_command(*command, timeout: 4)
  input = output = wait_thread = nil
  input, output, wait_thread = Open3.popen2e(*command)
  input.close
  text = Timeout.timeout(timeout) { output.read }
  [text, wait_thread.value]
rescue Timeout::Error
  terminate_command(wait_thread) if wait_thread
  raise "Automation command timed out after #{timeout} seconds."
ensure
  output&.close unless output&.closed?
  input&.close unless input&.closed?
end

def run_script(source)
  output, status = capture_command('/usr/bin/osascript', '-l', 'AppleScript', '-e', source)
  raise "osascript failed: #{output.strip}" unless status.success?

  output.strip
end

def expect_script_failure(source, code, message)
  output, status = capture_command('/usr/bin/osascript', '-l', 'AppleScript', '-e', source)
  raise message if status.success?
  return if output.match?(/\(#{Regexp.escape(code.to_s)}\)/)

  raise "#{message} Expected AppleScript error #{code}, got: #{output.strip}"
end

def wait_until(timeout: 8)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  loop do
    value = yield
    return value if value
    raise 'Timed out waiting for the automation fixture.' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

    sleep 0.05
  end
end

def wait_for_fixture(timeout: 12)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  loop do
    begin
      return yield
    rescue RuntimeError => error
      raise unless error.message.start_with?('Automation command timed out')
      raise error if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.1
    end
  end
end

def recorded_children(path)
  return [] unless File.exist?(path)

  File.readlines(path, chomp: true).filter_map { |value| Integer(value, exception: false) }.uniq
end

def hide_fixture(pid)
  script = <<~JAVASCRIPT
    ObjC.import('AppKit');
    const application = $.NSRunningApplication.runningApplicationWithProcessIdentifier(#{pid});
    if (application) application.hide;
  JAVASCRIPT
  output, status = capture_command('/usr/bin/osascript', '-l', 'JavaScript', '-e', script)
  raise "Could not hide the fixture: #{output.strip}" unless status.success?
end

def terminate_fixture(pid)
  begin
    Process.kill('TERM', pid)
  rescue Errno::ESRCH
    return
  end
  begin
    Timeout.timeout(3) { Process.wait(pid) }
  rescue Errno::ECHILD
    return
  rescue Timeout::Error
    begin Process.kill('KILL', pid); rescue Errno::ESRCH; end
    begin Process.wait(pid); rescue Errno::ECHILD; end
  end
end

def pane_ids(output)
  output.scan(/no\.helgesverre\.terminal\.pane\.[0-9A-Fa-f-]+/).uniq
end

begin
  FileUtils.cp_r(source, fixture)
  plist = File.join(fixture, 'Contents/Info.plist')
  system('/usr/libexec/PlistBuddy', '-c', "Set :CFBundleIdentifier #{bundle_id}", plist, exception: true)
  system('/usr/libexec/PlistBuddy', '-c', 'Set :CFBundleName Terminal Automation Fixture', plist, exception: true)
  system('/usr/libexec/PlistBuddy', '-c', 'Set :CFBundleDisplayName Terminal Automation Fixture', plist, exception: true)
  system('/usr/bin/codesign', '--force', '--sign', '-', fixture, exception: true)
  fixture_shell = File.join(fixture_root, 'fixture-shell')
  File.write(fixture_shell, <<~SH)
    #!/bin/sh
    printf '%s\\n' "$$" >> "$TERMINAL_AUTOMATION_CHILD_PIDS"
    exec /bin/sh -c 'stty raw -echo; exec /bin/cat'
  SH
  File.chmod(0o700, fixture_shell)

  command = 'stty raw -echo; printf "%s\\n" "$$" >> "$TERMINAL_AUTOMATION_CHILD_PIDS"; exec /bin/cat'
  app_pid = Process.spawn(
    { 'SHELL' => fixture_shell, 'TERMINAL_AUTOMATION_CHILD_PIDS' => child_pids_path },
    File.join(fixture, 'Contents/MacOS/Terminal'), '--working-directory', '/tmp',
    '--execute', '/bin/sh', '-c', command, out: File::NULL, err: File::NULL)
  child_pids = wait_until { recorded_children(child_pids_path).then { |pids| pids if pids.length == 1 } }

  app = applescript_literal(bundle_id)
  pane_id = wait_for_fixture { run_script("tell application id #{app} to focus pane") }
  raise "Invalid pane identifier: #{pane_id.inspect}" unless pane_id.start_with?('no.helgesverre.terminal.pane.')
  expect_script_failure(
    "tell application id #{app} to read screen from pane \"no.helgesverre.terminal.pane.missing\"",
    -1728,
    'An unknown pane identifier was accepted.')

  other_pane = run_script("tell application id #{app} to new window")
  raise "new window did not return a distinct pane: #{other_pane.inspect}" if other_pane == pane_id
  right_pane = run_script("tell application id #{app} to split right pane id #{applescript_literal(pane_id)}")
  below_pane = run_script("tell application id #{app} to split below pane id #{applescript_literal(right_pane)}")
  run_script("tell application id #{app} to show settings")
  tab_pane = run_script("tell application id #{app} to new tab")
  child_pids = wait_until { recorded_children(child_pids_path).then { |pids| pids if pids.length >= 5 } }
  expected_panes = [pane_id, other_pane, right_pane, below_pane, tab_pane].sort
  panes = pane_ids(run_script("tell application id #{app} to list panes"))
  raise "list panes did not return the complete fixture set: #{panes.inspect}" unless panes.sort == expected_panes
  focused = run_script("tell application id #{app} to focus pane pane id #{applescript_literal(pane_id)}")
  raise "focus pane returned a different pane: #{focused.inspect}" unless focused == pane_id
  expect_script_failure(
    "tell application id #{app} to read screen max characters 0",
    -1700,
    'A zero screen read limit was accepted.')
  expect_script_failure(
    "tell application id #{app} to read screen max characters 262145",
    -1700,
    'An oversized screen read limit was accepted.')
  expect_script_failure(
    "tell application id #{app} to configure preferences font size 7.0",
    -1700,
    'An invalid font size was accepted.')
  expect_script_failure(
    "tell application id #{app} to configure preferences starting directory \"/does/not/exist\"",
    -1700,
    'An invalid starting directory was accepted.')
  run_script("tell application id #{app} to show settings")
  hide_fixture(app_pid)

  accepted = run_script("tell application id #{app} to send text \"AUTOMATION_TEXT\"")
  raise "send text returned a different pane: #{accepted.inspect}" unless accepted == pane_id

  screen = wait_until do
    output = run_script("tell application id #{app} to read screen max characters 2048")
    output if output.include?('AUTOMATION_TEXT')
  end
  raise 'read screen did not return terminal output.' unless screen.include?('AUTOMATION_TEXT')

  configured = run_script(
    "tell application id #{app} to configure preferences font size 15.0 scrollback rows 1000 " \
    "option sends escape true follows tail on input false starting directory \"/tmp\"")
  raise "configure preferences did not return the saved font size: #{configured.inspect}" unless configured.include?('15')

  cleared = run_script("tell application id #{app} to clear screen")
  raise "clear screen returned a different pane: #{cleared.inspect}" unless cleared == pane_id
  run_script("tell application id #{app} to close pane pane id #{applescript_literal(tab_pane)}")
  run_script("tell application id #{app} to close pane pane id #{applescript_literal(below_pane)}")
  run_script("tell application id #{app} to close pane pane id #{applescript_literal(right_pane)}")
  run_script("tell application id #{app} to close pane pane id #{applescript_literal(other_pane)}")
  remaining = pane_ids(run_script("tell application id #{app} to list panes"))
  raise "close pane left the wrong pane set: #{remaining.inspect}" unless remaining == [pane_id]
  run_script("tell application id #{app} to quit")
  Timeout.timeout(8) { Process.wait(app_pid) }
  app_pid = nil
  child_pids |= recorded_children(child_pids_path)
  child_pids.each do |child_pid|
    begin
      Process.kill(0, child_pid)
      raise "Fixture PTY child #{child_pid} survived application exit."
    rescue Errno::ESRCH
      # Expected: AppDelegate's termination path reaped this controlled cat child.
    end
  end
  FileUtils.mkdir_p(File.dirname(report_path))
  File.write(report_path, JSON.pretty_generate(
    passed: true,
    panes_created: 5,
    child_processes_reaped: child_pids.length,
    scenarios: %w[invalid-target bounded-read preferences window split tab focus settings inactive close cleanup]
  ) + "\n")
  puts 'PASS AppleScript fixture: command delivery, bounded screen read, validated preferences, and clean PTY exit'
ensure
  child_pids |= recorded_children(child_pids_path)
  terminate_fixture(app_pid) if app_pid
  child_pids |= recorded_children(child_pids_path)
  system('/usr/bin/defaults', 'delete', bundle_id, out: File::NULL, err: File::NULL)
  FileUtils.remove_entry_secure(fixture_root) if File.directory?(fixture_root)
end
