#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'timeout'
require_relative 'native_smoke'

# Exercises the public AppleScript dictionary through a uniquely named, signed
# copy of the built app. The stable identity lets macOS retain the user's
# automation decision, while the lock and exact bundle path keep this harness
# from touching another Terminal instance.
class AppleScriptSmoke
  FIXTURE_BUNDLE_ID = 'no.helgesverre.terminal.automation-fixture'
  FIXTURE_NAME = 'Terminal Automation Fixture'
  EVENT_CLASS = 0x48546572 # HTer
  EVENT_ID = 0x6d666373 # mfcs
  COMMAND_TIMEOUT = 4
  CONSENT_TIMEOUT = 60
  OUTPUT_LIMIT = 8 * 1024
  LARGE_COMMITTED_TEXT = "AUTOMATION_TEXT_#{'x' * 4096}_END"

  class ConsentRequired < RuntimeError; end
  class ConsentDenied < RuntimeError; end
  class CommandTimeout < RuntimeError
    attr_reader :output, :status

    def initialize(seconds, output:, status:)
      super("Automation command timed out after #{seconds} seconds.")
      @output = output
      @status = status
    end
  end

  def initialize(root)
    @root = root
    @source = ENV.fetch('TERMINAL_AUTOMATION_SOURCE', File.join(root, 'dist', 'Terminal.app'))
    @fixture_root = ENV.fetch('TERMINAL_AUTOMATION_FIXTURE_ROOT', File.join(root, 'target', 'automation-fixture'))
    @fixture = File.join(@fixture_root, "#{FIXTURE_NAME}.app")
    @executable = File.join(@fixture, 'Contents', 'MacOS', 'Terminal')
    @report_path = ENV.fetch('TERMINAL_AUTOMATION_REPORT', File.join(root, 'reports', 'applescript-smoke.json'))
    @lock_path = ENV.fetch('TERMINAL_AUTOMATION_LOCK', File.join(root, 'target', 'automation-fixture.lock'))
    @request_consent = ENV['TERMINAL_AUTOMATION_REQUEST_CONSENT'] == '1'
    @preflight_only = ENV['TERMINAL_AUTOMATION_PREFLIGHT_ONLY'] == '1'
    @commands = []
    @child_pids = []
    @cleanup = {}
    @permission = nil
    @completed = false
  end

  def run
    begin
      acquire_lock
      validate_configuration
      prepare_fixture
      launch_fixture
      preflight_permission
      if @preflight_only
        finish_preflight
      else
        exercise_dictionary
        verify_clean_exit
      end
      @completed = true
    rescue StandardError => error
      @failure = "#{error.class}: #{error.message}"
      @run_error = error
    ensure
      @cleanup_error = finalize
    end
    raise @run_error if @run_error
    raise @cleanup_error if @cleanup_error

    puts "PASS AppleScript fixture: #{@preflight_only ? 'consent preflight' : 'command delivery, bounded reads, validated preferences, and clean PTY exit'}"
  end

  private

  def validate_configuration
    raise "Missing built app: #{@source}" unless File.executable?(File.join(@source, 'Contents', 'MacOS', 'Terminal'))
    @signing_identity = signing_identity
  end

  def signing_identity
    override = ENV['TERMINAL_AUTOMATION_SIGN_IDENTITY']
    return override unless override.to_s.empty?

    environment = ENV['APPLE_APPLICATION_SIGNING_IDENTITY']
    return environment unless environment.to_s.empty?

    path = File.expand_path('~/.config/terminal/release.json')
    configured = JSON.parse(File.read(path)).fetch('applicationIdentity', '') if File.file?(path)
    return configured unless configured.to_s.empty?

    identities, status = capture('/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning')
    raise "Could not inspect Developer ID identities: #{identities.strip}" unless status.success?

    matches = identities.scan(/"(Developer ID Application:[^"]+)"/).flatten
    return matches.first if matches.length == 1

    raise 'Configure APPLE_APPLICATION_SIGNING_IDENTITY or applicationIdentity in ~/.config/terminal/release.json.'
  rescue JSON::ParserError => error
    raise "Could not parse ~/.config/terminal/release.json: #{error.message}"
  end

  def acquire_lock
    FileUtils.mkdir_p(File.dirname(@lock_path))
    @lock = File.open(@lock_path, File::RDWR | File::CREAT, 0o600)
    File.chmod(0o600, @lock_path)
    if @lock.flock(File::LOCK_EX | File::LOCK_NB)
      @owns_lock = true
      return
    end

    raise "Another AppleScript fixture owns #{@fixture_root}; wait for that harness to finish."
  end

  def prepare_fixture
    raise "Refusing to replace active fixture process(es): #{active_fixture_pids.join(', ')}" unless active_fixture_pids.empty?

    FileUtils.remove_entry_secure(@fixture_root) if File.directory?(@fixture_root)
    FileUtils.mkdir_p(@fixture_root)
    FileUtils.cp_r(@source, @fixture)
    plist = File.join(@fixture, 'Contents', 'Info.plist')
    plist_set(plist, 'CFBundleIdentifier', FIXTURE_BUNDLE_ID)
    plist_set(plist, 'CFBundleName', FIXTURE_NAME)
    plist_set(plist, 'CFBundleDisplayName', FIXTURE_NAME)
    write_fixture_shell
    run_system('/usr/bin/codesign', '--force', '--options', 'runtime', '--sign', @signing_identity, @fixture)
    @fixture_signature = code_signature(@fixture)
    @source_signature = code_signature(@source)
    @source_sha256 = Digest::SHA256.file(File.join(@source, 'Contents', 'MacOS', 'Terminal')).hexdigest
    @source_revision = ENV['TERMINAL_AUTOMATION_SOURCE_REVISION']
    unless @source_revision
      revision, status = capture('/usr/bin/git', '-C', @root, 'rev-parse', 'HEAD')
      raise "Could not determine source revision: #{revision.strip}" unless status.success?

      @source_revision = revision.strip
    end
  end

  def launch_fixture
    assert_fixture_target_available
    @app_log = File.join(@fixture_root, 'fixture.log')
    @process = NativeSmokeProcess.new([
      {
        'SHELL' => @fixture_shell,
        'TERMINAL_AUTOMATION_CHILD_PIDS' => @child_pids_path,
        'TERMINAL_AUTOMATION_RECEIPT_SHELL' => @receipt_shell,
      },
      @executable, '--working-directory', '/tmp', '--execute', '/bin/sh', '-c', 'exec "$TERMINAL_AUTOMATION_RECEIPT_SHELL"',
      out: @app_log, err: @app_log
    ])
    @fixture_pid = @process.pid
    @child_pids = wait_until('fixture PTY child') do
      ensure_fixture_running
      pids = recorded_children
      pids if pids.length == 1
    end
  end

  def preflight_permission
    timeout = @request_consent ? CONSENT_TIMEOUT : COMMAND_TIMEOUT
    status = permission_status(ask_user_if_needed: @request_consent, timeout: timeout)
    @permission = { 'status' => status, 'outcome' => permission_name(status), 'requested_standard_consent' => @request_consent }
    return if status.zero?

    if status == -1744 && !@request_consent
      raise ConsentRequired, 'consent_required: non-prompting AppleEvent preflight returned -1744.'
    end

    raise ConsentDenied, "consent_denied: AppleEvent preflight returned #{status}."
  end

  def finish_preflight
    # The explicit request mode has already asked through macOS. This branch
    # retains the same cleanup and provenance guarantees as a full smoke.
  end

  def exercise_dictionary
    app = applescript_literal(FIXTURE_BUNDLE_ID)
    run_script("tell application id #{app} to get name", name: 'get fixture name')
    run_script("tell application id #{app} to get id", name: 'get fixture id')
    pane_id = wait_for_fixture { run_script("tell application id #{app} to focus pane", name: 'initial focus pane') }
    raise "Invalid pane identifier: #{pane_id.inspect}" unless pane_id.start_with?('no.helgesverre.terminal.pane.')
    expect_failure("tell application id #{app} to read screen from pane \"no.helgesverre.terminal.pane.missing\"", -1728,
                   'An unknown pane identifier was accepted.', name: 'reject unknown pane')

    other_pane = run_script("tell application id #{app} to new window", name: 'new window')
    raise "new window did not return a distinct pane: #{other_pane.inspect}" if other_pane == pane_id
    right_pane = run_script("tell application id #{app} to split right pane id #{applescript_literal(pane_id)}", name: 'split right')
    below_pane = run_script("tell application id #{app} to split below pane id #{applescript_literal(right_pane)}", name: 'split below')
    run_script("tell application id #{app} to show settings", name: 'show settings')
    tab_pane = run_script("tell application id #{app} to new tab", name: 'new tab')
    @child_pids = wait_until('split and tab PTY children') do
      ensure_fixture_running
      pids = recorded_children
      pids if pids.length >= 5
    end
    expected_panes = [pane_id, other_pane, right_pane, below_pane, tab_pane].sort
    panes = pane_ids(run_script("tell application id #{app} to list panes", name: 'list panes'))
    raise "list panes did not return the complete fixture set: #{panes.inspect}" unless panes.sort == expected_panes
    focused = run_script("tell application id #{app} to focus pane pane id #{applescript_literal(pane_id)}", name: 'focus named pane')
    raise "focus pane returned a different pane: #{focused.inspect}" unless focused == pane_id

    expect_failure("tell application id #{app} to read screen max characters 0", -1700,
                   'A zero screen read limit was accepted.', name: 'reject zero read limit')
    expect_failure("tell application id #{app} to read screen max characters 262145", -1700,
                   'An oversized screen read limit was accepted.', name: 'reject oversized read limit')
    expect_failure("tell application id #{app} to configure preferences font size 7.0", -1700,
                   'An invalid font size was accepted.', name: 'reject invalid font size')
    expect_failure("tell application id #{app} to configure preferences starting directory \"/does/not/exist\"", -1700,
                   'An invalid starting directory was accepted.', name: 'reject invalid directory')
    expect_failure("tell application id #{app} to configure preferences word characters \"not valid\"", -1700,
                   'Invalid selection word characters were accepted.', name: 'reject invalid word characters')
    run_script("tell application id #{app} to show settings", name: 'show settings while focused')
    hide_fixture

    accepted = run_script("tell application id #{app} to send text (#{applescript_literal(LARGE_COMMITTED_TEXT)} & return)",
                          name: 'send large committed text')
    raise "send text returned a different pane: #{accepted.inspect}" unless accepted == pane_id
    receipt = Digest::SHA256.hexdigest(LARGE_COMMITTED_TEXT)
    screen = wait_until('committed text receipt in screen snapshot') do
      output = run_script("tell application id #{app} to read screen max characters 2048", name: 'read screen')
      output if receipt_in_snapshot?(output, receipt)
    end
    raise 'read screen did not return the exact committed-text receipt.' unless receipt_in_snapshot?(screen, receipt)

    configured = run_script(
      "tell application id #{app} to configure preferences font size 15.0 scrollback rows 1000 " \
      'option sends escape true follows tail on input false starting directory "/tmp" word characters "@_/-@"', name: 'configure preferences')
    raise "configure preferences did not return the saved font size: #{configured.inspect}" unless configured.include?('15')
    unless configured.include?('word characters -/@_')
      raise "configure preferences did not return canonical word characters: #{configured.inspect}"
    end
    cleared = run_script("tell application id #{app} to clear screen", name: 'clear screen')
    raise "clear screen returned a different pane: #{cleared.inspect}" unless cleared == pane_id

    [[tab_pane, 'close tab pane'], [below_pane, 'close below pane'], [right_pane, 'close right pane'], [other_pane, 'close other window']].each do |id, name|
      run_script("tell application id #{app} to close pane pane id #{applescript_literal(id)}", name: name)
    end
    remaining = pane_ids(run_script("tell application id #{app} to list panes", name: 'list remaining panes'))
    raise "close pane left the wrong pane set: #{remaining.inspect}" unless remaining == [pane_id]
    run_script("tell application id #{app} to quit", name: 'quit fixture')
  end

  def verify_clean_exit
    status = @process.wait(8)
    raise 'Fixture app did not exit after quit.' unless status
    raise "Fixture app exited with #{describe_status(status)}" unless status.success?

    @child_pids |= recorded_children
    survivors = @child_pids.select { |pid| process_alive?(pid) }
    raise "Fixture PTY children survived application exit: #{survivors.join(', ')}" unless survivors.empty?
    raise "Fixture app left descendants: #{@process.live_pids.join(', ')}" unless @process.live_pids.empty?
  end

  def run_script(source, name:)
    output, status = invoke(name, 'AppleScript', source)
    raise "osascript failed: #{output.strip}" unless status.success?

    output.strip
  end

  def expect_failure(source, code, message, name:)
    output, status = invoke(name, 'AppleScript', source)
    raise message if status.success?
    return if output.match?(/\(#{Regexp.escape(code.to_s)}\)/)

    raise "#{message} Expected AppleScript error #{code}, got: #{output.strip}"
  end

  def hide_fixture
    script = <<~JAVASCRIPT
      ObjC.import('AppKit');
      const application = $.NSRunningApplication.runningApplicationWithProcessIdentifier(#{@fixture_pid});
      if (application) application.hide;
    JAVASCRIPT
    _output, status = invoke('hide fixture', 'JavaScript', script)
    raise 'Could not hide the fixture.' unless status.success?
  end

  def permission_status(ask_user_if_needed:, timeout:)
    script = <<~JAVASCRIPT
      ObjC.import('Foundation');
      ObjC.import('CoreServices');
      ObjC.bindFunction('AEDeterminePermissionToAutomateTarget', ['int', ['void*', 'uint32', 'uint32', 'bool']]);
      const target = $.NSAppleEventDescriptor.descriptorWithBundleIdentifier(#{FIXTURE_BUNDLE_ID.to_json});
      console.log(String($.AEDeterminePermissionToAutomateTarget(target.aeDesc, #{EVENT_CLASS}, #{EVENT_ID}, #{ask_user_if_needed ? 'true' : 'false'})));
    JAVASCRIPT
    output, status = invoke('AppleEvent permission preflight', 'JavaScript', script, timeout: timeout)
    raise "AppleEvent permission preflight failed: #{output.strip}" unless status.success?

    Integer(output.strip, exception: false) || raise("AppleEvent permission preflight returned non-numeric output: #{output.inspect}")
  end

  def invoke(name, language, source, timeout: COMMAND_TIMEOUT)
    output, status = capture('/usr/bin/osascript', '-l', language, '-e', source, timeout: timeout)
    @commands << command_record(name, language, source, output, status, false, timeout)
    [output, status]
  rescue CommandTimeout => error
    @commands << command_record(name, language, source, error.output, error.status, true, timeout)
    raise
  end

  def capture(*command, timeout: COMMAND_TIMEOUT)
    input = output = waiter = nil
    input, output, waiter = Open3.popen2e(*command)
    input.close
    text = Timeout.timeout(timeout) { output.read }
    [text, waiter.value]
  rescue Timeout::Error
    status = terminate_command(waiter)
    partial = output&.read.to_s
    raise CommandTimeout.new(timeout, output: partial, status: status)
  ensure
    output&.close unless output&.closed?
    input&.close unless input&.closed?
  end

  def terminate_command(waiter)
    return waiter.value if waiter.join(0)

    Process.kill('TERM', waiter.pid)
    Timeout.timeout(1) { waiter.value }
  rescue Errno::ESRCH
    waiter.value
  rescue Timeout::Error
    Process.kill('KILL', waiter.pid) rescue nil
    waiter.value
  end

  def wait_until(label, timeout: 8)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      value = yield
      return value if value
      raise "Timed out waiting for #{label}." if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.05
    end
  end

  def wait_for_fixture(timeout: 12)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      return yield
    rescue CommandTimeout
      raise if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.1
    end
  end

  def ensure_fixture_running
    status = @process.wait(0)
    raise "Fixture app exited during startup: #{describe_status(status)}" if status
  end

  def write_fixture_shell
    @child_pids_path = File.join(@fixture_root, 'children.pids')
    @fixture_shell = File.join(@fixture_root, 'fixture-shell')
    @receipt_shell = File.join(@fixture_root, 'fixture-receipt')
    File.write(@fixture_shell, <<~SHELL)
      #!/bin/sh
      printf '%s\\n' "$$" >> "$TERMINAL_AUTOMATION_CHILD_PIDS"
      exec /bin/sh -c 'stty raw -echo; exec /bin/cat'
    SHELL
    File.chmod(0o700, @fixture_shell)
    File.write(@receipt_shell, <<~RUBY)
      #!/usr/bin/env ruby
      require 'digest'
      STDIN.binmode
      STDOUT.binmode
      STDOUT.sync = true
      File.open(ENV.fetch('TERMINAL_AUTOMATION_CHILD_PIDS'), 'a') { |file| file.puts(Process.pid) }
      system('/bin/stty', 'raw', '-echo')
      digest = Digest::SHA256.new
      loop do
        chunk = STDIN.readpartial(4096)
        terminator = chunk.index("\\r".b)
        digest.update(terminator ? chunk.byteslice(0, terminator) : chunk)
        break if terminator
      end
      STDOUT.write("AUTOMATION_RECEIPT \#{digest.hexdigest}\\n")
      exec('/bin/cat')
    RUBY
    File.chmod(0o700, @receipt_shell)
  end

  def recorded_children
    return [] unless @child_pids_path && File.file?(@child_pids_path)

    File.readlines(@child_pids_path, chomp: true).filter_map { |value| Integer(value, exception: false) }.uniq
  end

  def active_fixture_pids
    output, status = Open3.capture2('/bin/ps', '-axo', 'pid=,command=')
    raise 'Cannot inspect active fixture process ownership.' unless status.success?

    output.lines.filter_map do |line|
      pid, command = line.strip.split(/\s+/, 2)
      Integer(pid, exception: false) if command&.include?(@executable)
    end
  end

  def assert_fixture_target_available
    expected_path = File.realpath(@fixture)
    identities = running_fixture_identities
    @targeting = { 'bundle_id' => FIXTURE_BUNDLE_ID, 'expected_path' => expected_path, 'running' => identities }
    conflicts = identities.reject { |identity| identity['bundle_path'] == expected_path }
    raise "Refusing AppleScript target collision for #{FIXTURE_BUNDLE_ID}: #{conflicts}" unless conflicts.empty?
    raise "Refusing to launch over active fixture PID(s): #{identities.map { |identity| identity['pid'] }.join(', ')}" unless identities.empty?
  end

  def running_fixture_identities
    script = <<~JAVASCRIPT
      ObjC.import('AppKit');
      const applications = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(#{FIXTURE_BUNDLE_ID.to_json});
      for (let index = 0; index < applications.count; index += 1) {
        const application = applications.objectAtIndex(index);
        console.log(`${application.processIdentifier}\\t${ObjC.unwrap(application.bundleURL.path)}`);
      }
    JAVASCRIPT
    output, status = capture('/usr/bin/osascript', '-l', 'JavaScript', '-e', script)
    raise "Could not inspect AppleScript target ownership: #{output.strip}" unless status.success?

    output.lines.filter_map do |line|
      pid, path = line.strip.split("\t", 2)
      parsed = Integer(pid, exception: false)
      { 'pid' => parsed, 'bundle_path' => File.realpath(path) } if parsed && path && File.exist?(path)
    end
  end

  def pane_ids(output)
    output.scan(/no\.helgesverre\.terminal\.pane\.[0-9A-Fa-f-]+/).uniq
  end

  def receipt_in_snapshot?(snapshot, receipt)
    snapshot.delete(" \t\r\n").include?("AUTOMATION_RECEIPT#{receipt}")
  end

  def applescript_literal(value)
    '"' + value.gsub('\\', '\\\\').gsub('"', '\\"') + '"'
  end

  def plist_set(path, key, value)
    run_system('/usr/libexec/PlistBuddy', '-c', "Set :#{key} #{value}", path)
  end

  def code_signature(path)
    output, status = capture('/usr/bin/codesign', '-dv', '--verbose=2', path)
    raise "Could not inspect code signature for #{path}: #{output.strip}" unless status.success?

    output
  end

  def run_system(*command)
    success = system(*command, out: File::NULL, err: File::NULL)
    raise "Command failed: #{command.join(' ')}" unless success
  end

  def command_record(name, language, source, output, status, timed_out, timeout)
    {
      'name' => name,
      'language' => language,
      'command' => ['/usr/bin/osascript', '-l', language, '-e', source],
      'timeout_seconds' => timeout,
      'script_sha256' => Digest::SHA256.hexdigest(source),
      'stdout' => truncate(output),
      'exit_status' => status&.exitstatus,
      'signaled' => status&.signaled?,
      'signal' => status&.termsig,
      'timed_out' => timed_out,
    }
  end

  def truncate(text)
    return text if text.bytesize <= OUTPUT_LIMIT

    prefix = text.byteslice(0, OUTPUT_LIMIT).force_encoding(Encoding::UTF_8).scrub
    "#{prefix}… [truncated #{text.bytesize - OUTPUT_LIMIT} bytes]"
  end

  def finalize
    return release_lock unless @owns_lock

    begin
      @child_pids |= recorded_children if @child_pids_path
      cleanup_error = cleanup_process
      write_report
      cleanup_error
    ensure
      release_lock
    end
  end

  def cleanup_process
    failure = cleanup_owned_process
    return failure unless @fixture_root && File.directory?(@fixture_root)

    active = active_fixture_pids
    @cleanup['active_fixture_pids_after_cleanup'] = active
    if active.empty?
      system('/usr/bin/defaults', 'delete', FIXTURE_BUNDLE_ID, out: File::NULL, err: File::NULL)
      FileUtils.remove_entry_secure(@fixture_root)
    else
      failure ||= RuntimeError.new("Refusing to remove active fixture process(es): #{active.join(', ')}")
    end
    record_cleanup_failure(failure) if failure
    failure
  rescue StandardError => error
    record_cleanup_failure(error)
    error
  end

  def cleanup_owned_process
    return unless @process

    @process.wait(0)
    @cleanup['owned_pids_before_cleanup'] = @process.live_pids
    survivors = @process.cleanup
    @cleanup['owned_pids_after_cleanup'] = @process.live_pids
    @cleanup['survivors'] = survivors
    @cleanup['app_exit_status'] = describe_status(@process.status)
    @child_pids |= recorded_children
    @cleanup['recorded_child_pids'] = @child_pids
    @cleanup['recorded_children_exited'] = @child_pids.all? { |pid| !process_alive?(pid) }
    @fixture_output = truncate(File.read(@app_log)) if @app_log && File.file?(@app_log)
    raise "Fixture cleanup left processes: #{survivors.join(', ')}" unless survivors.empty?
    raise 'Fixture cleanup left a recorded PTY child.' unless @cleanup['recorded_children_exited']
  rescue StandardError => error
    error
  end

  def record_cleanup_failure(error)
    @cleanup['error'] ||= "#{error.class}: #{error.message}"
    @failure ||= @cleanup['error']
  end

  def write_report
    FileUtils.mkdir_p(File.dirname(@report_path))
    File.write(@report_path, JSON.pretty_generate(
      'passed' => @completed && @failure.nil? && @cleanup['error'].nil?,
      'failure' => @failure,
      'source' => {
        'bundle_path' => @source,
        'revision' => @source_revision,
        'executable_sha256' => @source_sha256,
        'code_signature' => @source_signature,
      },
      'fixture' => {
        'bundle_id' => FIXTURE_BUNDLE_ID,
        'display_name' => FIXTURE_NAME,
        'path' => @fixture,
        'pid' => @fixture_pid,
        'signing_identity' => @signing_identity,
        'code_signature' => @fixture_signature,
      },
      'permission' => @permission,
      'targeting' => @targeting,
      'preflight_only' => @preflight_only,
      'commands' => @commands,
      'cleanup' => @cleanup,
      'fixture_stdout_stderr' => @fixture_output || '',
      'scenarios' => %w[permission invalid-target bounded-read preferences window split tab focus settings inactive large-committed-text clear close cleanup],
    ) + "\n")
  end

  def release_lock
    return unless @lock

    @lock.flock(File::LOCK_UN)
    @lock.close
    @lock = nil
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

  def permission_name(status)
    case status
    when 0 then 'permitted'
    when -1744 then 'consent_required'
    when -1743 then 'consent_denied'
    else "unexpected_status_#{status}"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  Signal.trap('TERM') { raise Interrupt, 'AppleScript smoke interrupted' }
  Signal.trap('INT') { raise Interrupt, 'AppleScript smoke interrupted' }
  begin
    AppleScriptSmoke.new(File.expand_path('..', __dir__)).run
  rescue AppleScriptSmoke::ConsentRequired => error
    warn error.message
    warn 'Run with TERMINAL_AUTOMATION_REQUEST_CONSENT=1 and TERMINAL_AUTOMATION_PREFLIGHT_ONLY=1 to request standard macOS consent for the stable fixture.'
    exit 2
  rescue AppleScriptSmoke::ConsentDenied => error
    warn error.message
    exit 3
  rescue StandardError => error
    warn "AppleScript smoke failed: #{error.message}"
    exit 1
  end
end
