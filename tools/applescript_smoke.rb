#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require 'securerandom'
require 'shellwords'
require 'timeout'
require 'tmpdir'

root = File.expand_path('..', __dir__)
source = ENV.fetch('TERMINAL_AUTOMATION_SOURCE', File.join(root, 'dist', 'Terminal.app'))
source = File.realpath(source)
abort "Missing built app: #{source}" unless File.executable?(File.join(source, 'Contents/MacOS/Terminal'))

stable_fixture = ENV['TERMINAL_AUTOMATION_STABLE_FIXTURE'] == '1'
fixture_root = if stable_fixture
                 File.join(root, 'target', 'automation-fixture')
               else
                 Dir.mktmpdir('helge-terminal-applescript-')
               end
if stable_fixture
  FileUtils.remove_entry_secure(fixture_root) if File.directory?(fixture_root)
  FileUtils.mkdir_p(fixture_root)
end
fixture = File.join(fixture_root, 'Terminal Automation Fixture.app')
bundle_id = if stable_fixture
              ENV.fetch('TERMINAL_AUTOMATION_FIXTURE_BUNDLE_ID', 'no.helgesverre.terminal.automation-fixture')
            else
              "no.helgesverre.terminal.automation-fixture.#{SecureRandom.hex(6)}"
            end
signing_identity = ENV['TERMINAL_AUTOMATION_SIGN_IDENTITY']
abort 'TERMINAL_AUTOMATION_SIGN_IDENTITY is required for a stable fixture.' if stable_fixture && signing_identity.to_s.empty?
request_consent = ENV['TERMINAL_AUTOMATION_REQUEST_CONSENT'] == '1'
abort 'Consent requests require TERMINAL_AUTOMATION_STABLE_FIXTURE=1.' if request_consent && !stable_fixture
preflight_only = ENV['TERMINAL_AUTOMATION_PREFLIGHT_ONLY'] == '1'
child_pids_path = File.join(fixture_root, 'children.pids')
report_path = ENV.fetch('TERMINAL_AUTOMATION_REPORT', File.join(root, 'reports', 'applescript-smoke.json'))
app_pid = nil
fixture_pid = nil
fixture_identity = nil
launcher_pid = nil
child_pids = []
commands = []
failure = nil
fixture_process = nil
app_log = nil
app_log_output = ''
launch_mode = ENV.fetch('TERMINAL_AUTOMATION_LAUNCH', 'direct')
permission_preflight = nil
permission_outcome = nil
fixture_signature = nil

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

class AutomationCommandTimeout < RuntimeError
  attr_reader :output, :status

  def initialize(timeout, output, status)
    super("Automation command timed out after #{timeout} seconds.")
    @output = output
    @status = status
  end
end

class AutomationConsentRequired < RuntimeError
  def initialize
    super('consent_required: non-prompting AppleEvent preflight returned -1744.')
  end
end

def capture_command(*command, timeout: 4, sample: nil)
  input = output = wait_thread = nil
  input, output, wait_thread = Open3.popen2e(*command)
  input.close
  sampler = if sample
              Thread.new do
                sleep sample.fetch(:after, 1)
                system('/usr/bin/sample', sample.fetch(:pid).to_s, '1', '1', '-file', sample.fetch(:path),
                       out: File::NULL, err: File::NULL)
              end
            end
  text = Timeout.timeout(timeout) { output.read }
  [text, wait_thread.value]
rescue Timeout::Error
  status = terminate_command(wait_thread) if wait_thread
  raise AutomationCommandTimeout.new(timeout, output&.read.to_s, status)
ensure
  sampler&.join
  output&.close unless output&.closed?
  input&.close unless input&.closed?
end

def run_script(source, commands:, name:, sample: nil)
  output, status = capture_command('/usr/bin/osascript', '-l', 'AppleScript', '-e', source, sample: sample)
  commands << { name: name, language: 'AppleScript', source: source, stdout: output.strip,
                exit_status: status.exitstatus, timed_out: false }
  raise "osascript failed: #{output.strip}" unless status.success?

  output.strip
rescue AutomationCommandTimeout => error
  commands << { name: name, language: 'AppleScript', source: source, stdout: error.output.strip,
                exit_status: error.status&.exitstatus, timed_out: true }
  raise
end

def expect_script_failure(source, code, message, commands:, name:)
  output, status = capture_command('/usr/bin/osascript', '-l', 'AppleScript', '-e', source)
  commands << { name: name, language: 'AppleScript', source: source, stdout: output.strip,
                exit_status: status.exitstatus, timed_out: false }
  raise message if status.success?
  return if output.match?(/\(#{Regexp.escape(code.to_s)}\)/)

  raise "#{message} Expected AppleScript error #{code}, got: #{output.strip}"
rescue AutomationCommandTimeout => error
  commands << { name: name, language: 'AppleScript', source: source, stdout: error.output.strip,
                exit_status: error.status&.exitstatus, timed_out: true }
  raise
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
    rescue AutomationCommandTimeout => error
      raise error if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.1
    end
  end
end

def recorded_children(path)
  return [] unless File.exist?(path)

  File.readlines(path, chomp: true).filter_map { |value| Integer(value, exception: false) }.uniq
end

def running_application(bundle_id, bundle_path)
  script = <<~JAVASCRIPT
    ObjC.import('AppKit');
    const apps = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(#{bundle_id.to_json});
    for (let index = 0; index < apps.count; index += 1) {
      const application = apps.objectAtIndex(index);
      const path = ObjC.unwrap(application.bundleURL.path);
      if (path === #{bundle_path.to_json}) {
        console.log(`${application.processIdentifier}\\t${path}`);
      }
    }
  JAVASCRIPT
  output, status = capture_command('/usr/bin/osascript', '-l', 'JavaScript', '-e', script)
  return nil unless status.success?

  pid, path = output.strip.split("\t", 2)
  return nil unless path == bundle_path

  parsed_pid = Integer(pid, exception: false)
  parsed_pid && { pid: parsed_pid, bundle_path: path }
end

def automation_permission_status(bundle_id, ask_user_if_needed:)
  script = <<~JAVASCRIPT
    ObjC.import('Foundation');
    ObjC.import('CoreServices');
    ObjC.bindFunction('AEDeterminePermissionToAutomateTarget', ['int', ['void*', 'uint32', 'uint32', 'bool']]);
    const target = $.NSAppleEventDescriptor.descriptorWithBundleIdentifier(#{bundle_id.to_json});
    console.log(String($.AEDeterminePermissionToAutomateTarget(target.aeDesc, 0x48546572, 0x6d666373, #{ask_user_if_needed ? 'true' : 'false'})));
  JAVASCRIPT
  output, status = capture_command('/usr/bin/osascript', '-l', 'JavaScript', '-e', script)
  raise "AppleEvent permission preflight failed: #{output.strip}" unless status.success?

  Integer(output.strip, exception: false)
end

def permission_status_name(status)
  case status
  when 0 then 'permitted'
  when -1744 then 'consent_required'
  when -1743 then 'consent_denied'
  else "unexpected_status_#{status}"
  end
end

def code_signature(path)
  output, status = capture_command('/usr/bin/codesign', '-dv', '--verbose=2', path)
  raise "Could not inspect fixture signature: #{output.strip}" unless status.success?

  output
end

def hide_fixture(pid, commands:)
  script = <<~JAVASCRIPT
    ObjC.import('AppKit');
    const application = $.NSRunningApplication.runningApplicationWithProcessIdentifier(#{pid});
    if (application) application.hide;
  JAVASCRIPT
  output, status = capture_command('/usr/bin/osascript', '-l', 'JavaScript', '-e', script)
  commands << { name: 'hide fixture', language: 'JavaScript', source: script, stdout: output.strip,
                exit_status: status.exitstatus, timed_out: false }
  raise "Could not hide the fixture: #{output.strip}" unless status.success?
rescue AutomationCommandTimeout => error
  commands << { name: 'hide fixture', language: 'JavaScript', source: script, stdout: error.output.strip,
                exit_status: error.status&.exitstatus, timed_out: true }
  raise
end

def process_exited?(pid)
  begin
    Process.wait(pid, Process::WNOHANG)
    return true
  rescue Errno::ECHILD
    # The LaunchServices process is not our child; fall through to its PID.
  end
  begin
    Process.kill(0, pid)
    false
  rescue Errno::ESRCH
    true
  end
end

def wait_for_exit(pid, timeout: 3)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  loop do
    return true if process_exited?(pid)
    return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

    sleep 0.05
  end
end

def terminate_fixture(pid)
  begin
    Process.kill('TERM', pid)
  rescue Errno::ESRCH
    return
  end
  return if wait_for_exit(pid)

  begin Process.kill('KILL', pid); rescue Errno::ESRCH; end
  wait_for_exit(pid, timeout: 1)
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
  fixture_shell = File.join(fixture_root, 'fixture-shell')
  File.write(fixture_shell, <<~SH)
    #!/bin/sh
    printf '%s\\n' "$$" >> "$TERMINAL_AUTOMATION_CHILD_PIDS"
    exec /bin/sh -c 'stty raw -echo; exec /bin/cat'
  SH
  File.chmod(0o700, fixture_shell)
  if launch_mode == 'open'
    system('/usr/libexec/PlistBuddy', '-c', 'Add :LSEnvironment dict', plist, exception: true)
    system('/usr/libexec/PlistBuddy', '-c', "Add :LSEnvironment:SHELL string #{fixture_shell}", plist, exception: true)
    system('/usr/libexec/PlistBuddy', '-c', "Add :LSEnvironment:TERMINAL_AUTOMATION_CHILD_PIDS string #{child_pids_path}", plist, exception: true)
  elsif launch_mode != 'direct'
    raise "Unsupported fixture launch mode: #{launch_mode.inspect}"
  end
  if stable_fixture
    system('/usr/bin/codesign', '--force', '--options', 'runtime', '--sign', signing_identity, fixture, exception: true)
  else
    system('/usr/bin/codesign', '--force', '--sign', '-', fixture, exception: true)
  end
  fixture_signature = code_signature(fixture)

  command = 'stty raw -echo; printf "%s\\n" "$$" >> "$TERMINAL_AUTOMATION_CHILD_PIDS"; exec /bin/cat'
  app_log = File.join(fixture_root, 'fixture.log')
  if launch_mode == 'open'
    launcher_pid = Process.spawn('/usr/bin/open', '-W', '-n', fixture, '--args', '--working-directory', '/tmp',
      '--execute', '/bin/sh', '-c', command, out: app_log, err: app_log)
    fixture_identity = wait_until { running_application(bundle_id, File.realpath(fixture)) }
    app_pid = fixture_identity.fetch(:pid)
  else
    app_pid = Process.spawn(
      { 'SHELL' => fixture_shell, 'TERMINAL_AUTOMATION_CHILD_PIDS' => child_pids_path },
      File.join(fixture, 'Contents/MacOS/Terminal'), '--working-directory', '/tmp',
      '--execute', '/bin/sh', '-c', command, out: app_log, err: app_log)
    fixture_identity = { pid: app_pid, bundle_path: File.realpath(fixture) }
  end
  fixture_pid = app_pid
  child_pids = wait_until { recorded_children(child_pids_path).then { |pids| pids if pids.length == 1 } }
  fixture_process = `ps -p #{app_pid} -o pid=,ppid=,state=,etime=,command=`.strip

  app = applescript_literal(bundle_id)
  run_script("tell application id #{app} to get name", commands: commands, name: 'get fixture name')
  run_script("tell application id #{app} to get id", commands: commands, name: 'get fixture id')
  permission_preflight = automation_permission_status(bundle_id, ask_user_if_needed: request_consent)
  permission_outcome = permission_status_name(permission_preflight)
  raise AutomationConsentRequired if permission_preflight == -1744
  raise "AppleEvent automation permission was denied (#{permission_preflight})." unless permission_preflight.zero?
  if preflight_only
    puts "PASS AppleScript fixture: #{request_consent ? 'consent request' : 'non-prompting'} preflight permitted"
    exit
  end
  sample = if (path = ENV['TERMINAL_AUTOMATION_SAMPLE']).nil?
             nil
           else
             { pid: app_pid, path: path }
           end
  pane_id = wait_for_fixture {
    pending_sample = commands.any? { |entry| entry[:name] == 'initial focus pane' } ? nil : sample
    run_script("tell application id #{app} to focus pane", commands: commands, name: 'initial focus pane', sample: pending_sample)
  }
  raise "Invalid pane identifier: #{pane_id.inspect}" unless pane_id.start_with?('no.helgesverre.terminal.pane.')
  expect_script_failure(
    "tell application id #{app} to read screen from pane \"no.helgesverre.terminal.pane.missing\"",
    -1728,
    'An unknown pane identifier was accepted.', commands: commands, name: 'unknown pane')

  other_pane = run_script("tell application id #{app} to new window", commands: commands, name: 'new window')
  raise "new window did not return a distinct pane: #{other_pane.inspect}" if other_pane == pane_id
  right_pane = run_script("tell application id #{app} to split right pane id #{applescript_literal(pane_id)}", commands: commands, name: 'split right')
  below_pane = run_script("tell application id #{app} to split below pane id #{applescript_literal(right_pane)}", commands: commands, name: 'split below')
  run_script("tell application id #{app} to show settings", commands: commands, name: 'show settings')
  tab_pane = run_script("tell application id #{app} to new tab", commands: commands, name: 'new tab')
  child_pids = wait_until { recorded_children(child_pids_path).then { |pids| pids if pids.length >= 5 } }
  expected_panes = [pane_id, other_pane, right_pane, below_pane, tab_pane].sort
  panes = pane_ids(run_script("tell application id #{app} to list panes", commands: commands, name: 'list panes'))
  raise "list panes did not return the complete fixture set: #{panes.inspect}" unless panes.sort == expected_panes
  focused = run_script("tell application id #{app} to focus pane pane id #{applescript_literal(pane_id)}", commands: commands, name: 'focus named pane')
  raise "focus pane returned a different pane: #{focused.inspect}" unless focused == pane_id
  expect_script_failure(
    "tell application id #{app} to read screen max characters 0",
    -1700,
    'A zero screen read limit was accepted.', commands: commands, name: 'reject zero read limit')
  expect_script_failure(
    "tell application id #{app} to read screen max characters 262145",
    -1700,
    'An oversized screen read limit was accepted.', commands: commands, name: 'reject oversized read limit')
  expect_script_failure(
    "tell application id #{app} to configure preferences font size 7.0",
    -1700,
    'An invalid font size was accepted.', commands: commands, name: 'reject invalid font size')
  expect_script_failure(
    "tell application id #{app} to configure preferences starting directory \"/does/not/exist\"",
    -1700,
    'An invalid starting directory was accepted.', commands: commands, name: 'reject invalid directory')
  run_script("tell application id #{app} to show settings", commands: commands, name: 'show settings while focused')
  hide_fixture(app_pid, commands: commands)

  accepted = run_script("tell application id #{app} to send text \"AUTOMATION_TEXT\"", commands: commands, name: 'send text')
  raise "send text returned a different pane: #{accepted.inspect}" unless accepted == pane_id

  screen = wait_until do
    output = run_script("tell application id #{app} to read screen max characters 2048", commands: commands, name: 'read screen')
    output if output.include?('AUTOMATION_TEXT')
  end
  raise 'read screen did not return terminal output.' unless screen.include?('AUTOMATION_TEXT')

  configured = run_script(
    "tell application id #{app} to configure preferences font size 15.0 scrollback rows 1000 " \
    "option sends escape true follows tail on input false starting directory \"/tmp\"", commands: commands,
    name: 'configure preferences')
  raise "configure preferences did not return the saved font size: #{configured.inspect}" unless configured.include?('15')

  cleared = run_script("tell application id #{app} to clear screen", commands: commands, name: 'clear screen')
  raise "clear screen returned a different pane: #{cleared.inspect}" unless cleared == pane_id
  run_script("tell application id #{app} to close pane pane id #{applescript_literal(tab_pane)}", commands: commands, name: 'close tab pane')
  run_script("tell application id #{app} to close pane pane id #{applescript_literal(below_pane)}", commands: commands, name: 'close below pane')
  run_script("tell application id #{app} to close pane pane id #{applescript_literal(right_pane)}", commands: commands, name: 'close right pane')
  run_script("tell application id #{app} to close pane pane id #{applescript_literal(other_pane)}", commands: commands, name: 'close other window')
  remaining = pane_ids(run_script("tell application id #{app} to list panes", commands: commands, name: 'list remaining panes'))
  raise "close pane left the wrong pane set: #{remaining.inspect}" unless remaining == [pane_id]
  run_script("tell application id #{app} to quit", commands: commands, name: 'quit fixture')
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
  puts 'PASS AppleScript fixture: command delivery, bounded screen read, validated preferences, and clean PTY exit'
rescue StandardError => error
  failure = "#{error.class}: #{error.message}"
  raise
ensure
  child_pids |= recorded_children(child_pids_path)
  app_log_output = File.read(app_log) if app_log && File.exist?(app_log)
  if app_pid.nil? && launch_mode == 'open' && File.directory?(fixture)
    fixture_identity = running_application(bundle_id, File.realpath(fixture))
    app_pid = fixture_identity[:pid] if fixture_identity
  end
  terminate_fixture(app_pid) if app_pid
  terminate_fixture(launcher_pid) if launcher_pid && !process_exited?(launcher_pid)
  child_pids |= recorded_children(child_pids_path)
  system('/usr/bin/defaults', 'delete', bundle_id, out: File::NULL, err: File::NULL)
  FileUtils.remove_entry_secure(fixture_root) if File.directory?(fixture_root)
  FileUtils.mkdir_p(File.dirname(report_path))
  File.write(report_path, JSON.pretty_generate(
    passed: failure.nil?, failure: failure, source: source, source_signature: `codesign -dv --verbose=2 #{Shellwords.escape(source)} 2>&1`,
    bundle_id: bundle_id, fixture_pid: fixture_pid, fixture_identity: fixture_identity,
    fixture_path: fixture, stable_fixture: stable_fixture, signing_identity: signing_identity,
    fixture_signature: fixture_signature, launch_mode: launch_mode, fixture_process: fixture_process,
    automation_permission_status: permission_preflight, automation_permission_outcome: permission_outcome,
    requested_standard_consent: request_consent, preflight_only: preflight_only,
    fixture_stdout_stderr: app_log_output, child_processes_recorded: child_pids, commands: commands,
    scenarios: %w[invalid-target bounded-read preferences window split tab focus settings inactive close cleanup]
  ) + "\n")
end
