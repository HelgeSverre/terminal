#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'securerandom'
require 'shellwords'
require 'tmpdir'
require_relative 'native_smoke'

# This runner owns the entire disposable process tree. It copies and ad-hoc
# signs the built bundle before launch so an in-progress build cannot replace
# the executable being proved. The shell command is deliberately non-login and
# fixed: it neither reads a user's startup files nor their command history.
class AccessibilitySmoke
  REPORT_DIRECTORY = 'reports/accessibility-attributed'
  PANE_IDENTIFIER_PREFIX = 'no.helgesverre.terminal.pane.'

  def initialize(root, bundle)
    @root = root
    @bundle = bundle
    @report_directory = ENV.fetch('TERMINAL_ACCESSIBILITY_REPORT_DIRECTORY', File.join(root, REPORT_DIRECTORY))
    @report_path = File.join(@report_directory, 'external-ax.json')
    @provenance_path = File.join(@report_directory, 'provenance.json')
    @probe_source = File.join(root, 'tools', 'AccessibilityProbe.swift')
    @provenance = {
      'runner' => File.basename(__FILE__),
      'source_bundle' => bundle,
      'source_file_sha256' => Digest::SHA256.file(@probe_source).hexdigest,
      'permission_prompt_requested' => false,
    }
  end

  def run
    FileUtils.mkdir_p(@report_directory)
    File.delete(@report_path) if File.exist?(@report_path)
    Dir.mktmpdir('terminal-accessibility-attributed-') do |temporary|
      @probe_binary = File.join(temporary, 'AccessibilityProbe')
      compile_probe
      fixture = File.join(temporary, 'Terminal.app')
      FileUtils.cp_r(@bundle, fixture)
      identifier = "no.helgesverre.terminal.accessibility-fixture.#{SecureRandom.hex(6)}"
      system('/usr/libexec/PlistBuddy', '-c', "Set :CFBundleIdentifier #{identifier}",
        File.join(fixture, 'Contents', 'Info.plist'), exception: true)
      system('/usr/bin/codesign', '--force', '--sign', '-', fixture, exception: true)
      executable = File.join(fixture, 'Contents', 'MacOS', 'Terminal')
      child_pid_path = File.join(temporary, 'controlled-child.pid')
      command = fixture_command(child_pid_path)
      launch = [executable, '--columns', '80', '--rows', '24', '--font-size', '14',
        '--working-directory', '/tmp', '--execute', '/bin/sh', '-c', command]
      @provenance.merge!(
        'private_fixture_bundle' => fixture,
        'fixture_bundle_id' => identifier,
        'source_executable_sha256' => Digest::SHA256.file(File.join(@bundle, 'Contents', 'MacOS', 'Terminal')).hexdigest,
        'fixture_executable_sha256' => Digest::SHA256.file(executable).hexdigest,
        'probe_binary_sha256' => Digest::SHA256.file(@probe_binary).hexdigest,
        'command' => launch,
        'controlled_child_pid_file' => File.basename(child_pid_path))
      process = NativeSmokeProcess.new([*launch, out: File::NULL, err: File::NULL])
      @provenance['owned_app_pid'] = process.pid
      begin
        wait_for_external_probe(process)
        record_child_pid(child_pid_path)
      rescue Exception => error
        @provenance['runner_error'] = error.message
        raise
      ensure
        cleanup(process)
        write_provenance
      end
    end
    result = JSON.parse(File.read(@report_path))
    raise "Accessibility probe failed: #{result['error'] || result['assertions']}" unless result['passed']
    puts 'PASS external accessibility attributed-text fixture, read-only AXValue, styles, link, and cleanup'
  end

  private

  def compile_probe
    system('xcrun', 'swiftc', '-framework', 'AppKit', '-framework', 'ApplicationServices', @probe_source,
      '-o', @probe_binary, exception: true)
  end

  def fixture_command(child_pid_path)
    # SGR makes bold/underline/foreground/background runs; OSC 8 creates an
    # AXLink. é and 🐈 make the first styled AX run exactly five UTF-16 units.
    "printf '\\033[31;44;1;4mAXé🐈\\033[0m \\033]8;;https://example.test/ax\\033\\\\link\\033]8;;\\033\\\\\\n'; " \
      "printf '%s\\n' \"$$\" > #{Shellwords.escape(child_pid_path)}; exec /bin/sleep 30"
  end

  def wait_for_external_probe(process)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 12
    loop do
      probe = NativeSmokeProcess.new([
        @probe_binary, '--pid', process.pid.to_s,
        '--identifier', PANE_IDENTIFIER_PREFIX, '--report', @report_path
      ])
      begin
        raise 'External accessibility query timed out' unless probe.wait(6)
      ensure
        remaining = probe.cleanup
        raise "Accessibility probe survivors: #{remaining.join(', ')}" unless remaining.empty?
      end
      result = JSON.parse(File.read(@report_path)) if File.exist?(@report_path)
      return if result && result['passed']
      return if result && result['error'].to_s.include?('AXIsProcessTrustedWithOptions')
      # A pane-shaped report means the AX server has responded. Preserve its
      # evidence rather than retrying a real style/link assertion failure.
      return if result && result['pane']
      raise 'Accessibility fixture exited before its pane became readable' if process.wait(0)
      raise "Accessibility pane was not readable: #{result && result['error']}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.2
    end
  end

  def record_child_pid(path)
    return unless File.file?(path)

    pid = Integer(File.read(path).strip, 10)
    @provenance['controlled_child_pid'] = pid
  rescue ArgumentError
    @provenance['controlled_child_pid_error'] = 'fixture wrote a non-integer child PID'
  end

  def cleanup(process)
    # Observe once before recording ownership so the controlled PTY descendant
    # is included in NativeSmokeProcess's process-tree snapshot.
    process.wait(0)
    @provenance['owned_pids_before_cleanup'] = process.live_pids
    remaining = process.cleanup
    @provenance['owned_pids_after_cleanup'] = process.live_pids
    @provenance['cleanup_survivors'] = remaining
    status = process.status
    @provenance['app_exit_status'] = describe_status(status)
    child = @provenance['controlled_child_pid']
    @provenance['controlled_child_exited'] = !process_alive?(child) if child
    raise "Accessibility fixture survivors: #{remaining.join(', ')}" unless remaining.empty?
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def describe_status(status)
    return { 'observed' => false } unless status

    {
      'observed' => true,
      'exited' => status.exited?,
      'exit_status' => status.exitstatus,
      'signaled' => status.signaled?,
      'signal' => status.termsig,
    }
  end

  def write_provenance
    File.write(@provenance_path, JSON.pretty_generate(@provenance) + "\n")
  end
end

if $PROGRAM_NAME == __FILE__
  Signal.trap('TERM') { raise Interrupt, 'Accessibility smoke interrupted' }
  Signal.trap('INT') { raise Interrupt, 'Accessibility smoke interrupted' }
  abort 'Usage: ruby tools/accessibility_smoke.rb [app-bundle]' if ARGV.length > 1

  root = File.expand_path('..', __dir__)
  bundle = File.expand_path(ARGV.fetch(0, 'dist/Terminal.app'), root)
  executable = File.join(bundle, 'Contents', 'MacOS', 'Terminal')
  abort "Missing executable: #{executable}" unless File.executable?(executable)
  AccessibilitySmoke.new(root, bundle).run
end
