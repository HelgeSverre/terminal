#!/usr/bin/env ruby
# frozen_string_literal: true

# Disposable SHELL replacement: relay an actual workload through an inner PTY,
# recording bounded binary events while forwarding input, output and geometry.
require 'base64'
require 'digest'
require 'fileutils'
require 'io/console'
require 'json'
require 'pty'
require 'stringio'

class WorkloadFixture
  OUTPUT_LIMIT = 4 * 1024 * 1024
  READ_LIMIT = 16 * 1024
  REAP_GRACE_SECONDS = 0.5
  REAP_KILL_SECONDS = 1.0
  CANARY_TAIL_LIMIT = 8192

  def initialize
    @directory = File.realpath(ENV.fetch('TERMINAL_TUI_STRESS_DIRECTORY'))
    @workload = ENV.fetch('TERMINAL_TUI_STRESS_WORKLOAD')
    @cwd = File.realpath(ENV.fetch('TERMINAL_TUI_STRESS_CWD'))
    raise 'unsupported workload' unless %w[codex files].include?(@workload)
    @stopping = false
    @resize_pending = true
    @final_emitted = false
    @output_bytes = 0
    @sequence = 0
    @workload_tail = ''.b
    @workload_canaries = {}
    @pane = allocate_pane
    @events = File.open(File.join(@directory, "pane-#{@pane}-events.jsonl"), File::WRONLY | File::CREAT | File::APPEND, 0o600)
    @events.sync = true
    install_signals
    write_metadata
  end

  def run
    failure = nil
    begin
      STDOUT.sync = true
      system('/bin/stty', 'raw', '-echo') or raise 'could not configure fixture terminal'
      @workload == 'files' ? run_files : run_codex
    rescue Exception => error
      failure = error
    ensure
      begin
        wait_child
      rescue Exception => error
        failure ||= error
      ensure
        close_child_fds
      end
      @failure = failure && "#{failure.class}: #{failure.message}"
      begin
        write_final
      rescue Exception => error
        failure ||= error
      ensure
        @events&.close
      end
    end
    raise failure if failure
  end

  def self.self_test
    raise unless Base64.strict_encode64("猫".b) == '54yr'
    raise unless OUTPUT_LIMIT > READ_LIMIT
    raise unless Process.clock_gettime(Process::CLOCK_UPTIME_RAW).positive?
    events = StringIO.new
    probe = allocate
    probe.instance_variable_set(:@child, Process.spawn('/usr/bin/true'))
    probe.instance_variable_set(:@child_exit_recorded, false)
    probe.instance_variable_set(:@events, events)
    probe.instance_variable_set(:@sequence, 0)
    probe.instance_variable_set(:@pane, 0)
    sleep 0.02
    probe.send(:terminate_and_reap)
    receipt = JSON.parse(events.string)
    raise 'exited child was signalled instead of reaped' unless receipt.fetch('status').fetch('exited') && receipt.dig('status', 'exitstatus') == 0
    puts 'PASS tui-stress fixture: binary transcript, PTY geometry and lifecycle bounds'
  end

  private

  def allocate_pane
    path = File.join(@directory, 'pane-counter')
    File.open(path, File::RDWR | File::CREAT, 0o600) do |file|
      file.flock(File::LOCK_EX)
      id = file.read.to_i
      raise 'too many workload panes' unless (0...8).cover?(id)
      file.rewind; file.truncate(0); file.write((id + 1).to_s)
      id
    end
  end

  def install_signals
    # Signal handlers only transition state; reaping occurs on the relay path.
    %w[TERM HUP INT].each { |name| Signal.trap(name) { @stopping = true } }
    Signal.trap('WINCH') { @resize_pending = true }
  end

  def binary(name)
    path = File.realpath(ENV.fetch("TERMINAL_TUI_STRESS_#{name.upcase}"))
    raise "#{name} is not executable" unless File.executable?(path)
    path
  end

  def command
    case @workload
    when 'files' then [binary('files'), '--color=always', '--no-git', '-L', '3', @cwd]
    when 'codex'
      base_url = codex_base_url
      [binary('codex'), '--no-daemon', '--disable', 'plugin_discovery_prefetch', '--disable', 'remote_plugin',
       '--disable', 'recommended_plugins', '--disable', 'plugins', '-C', @cwd,
       '-c', 'model_provider="fixture"', '-c', 'model="fixture-model"',
       '-c', 'model_providers.fixture.name="Terminal fixture"',
       '-c', "model_providers.fixture.base_url=#{base_url.inspect}",
       '-c', 'model_providers.fixture.env_key="DUMMY_CODEX_UI_KEY"',
       '-c', 'model_providers.fixture.wire_api="responses"',
       '-c', 'model_providers.fixture.requires_openai_auth=false',
       '-c', 'model_providers.fixture.supports_websockets=false', 'Render fixture output']
    end
  end

  def child_environment
    environment = { 'TERM' => ENV.fetch('TERM', 'xterm-256color'), 'COLORTERM' => ENV.fetch('COLORTERM', 'truecolor'),
      'TERM_PROGRAM' => ENV.fetch('TERM_PROGRAM', 'HelgeTerminal'), 'NO_COLOR' => nil,
      'CLICOLOR' => '1', 'CLICOLOR_FORCE' => '1', 'FORCE_COLOR' => '1' }
    if @workload == 'codex'
      codex_directory_root = File.realpath(ENV.fetch('TERMINAL_TUI_STRESS_CODEX_DIRECTORY'))
      task_codex_directory = File.join(codex_directory_root, "pane-#{@pane}")
      FileUtils.mkdir_p(task_codex_directory)
      # CODEX_HOME is intentionally scoped to the actual Codex child only.
      environment['CODEX_HOME'] = task_codex_directory
      environment['CODEX_DISABLE_DAEMON'] = '1'
      environment['DUMMY_CODEX_UI_KEY'] = 'fixture-not-a-secret'
    end
    environment
  end

  def codex_base_url
    base_url = ENV.fetch('TERMINAL_TUI_STRESS_CODEX_BASE_URL')
    unless base_url.match?(%r{\Ahttp://127\.0\.0\.1:\d+/v1\z})
      raise 'Codex fixture provider must be a local /v1 endpoint'
    end
    base_url
  end

  def spawn_child
    # PTY.spawn creates the controlling session for the inner program. Asking
    # posix_spawn to set a second process group is rejected on macOS here.
    @reader, @writer, @child = PTY.spawn(child_environment, *command, chdir: @cwd)
    @child_exit_recorded = false
    @resize_pending = true
    record('child_started', pid: @child, executable_sha256: Digest::SHA256.file(command.first).hexdigest,
      command: command.map { |part| part == @cwd ? '<fixture-cwd>' : part })
  end

  def run_codex
    spawn_child
    relay_until_exit
  end

  def run_files
    until @stopping
      spawn_child
      relay_until_exit
      break if @stopping
      record('files_refresh_complete')
      sleep 0.18
    end
  end

  def relay_until_exit
    status = nil
    inner_closed = false
    until @stopping || status || inner_closed
      emit_final_marker if !@final_emitted && File.exist?(File.join(@directory, 'final-output'))
      apply_resize if @resize_pending
      ready = IO.select([STDIN, @reader], nil, nil, 0.08)
      Array(ready&.first).each do |io|
        if io.equal?(STDIN)
          forward_input
        else
          inner_closed = forward_output == :closed
        end
      end
      status = Process.waitpid2(@child, Process::WNOHANG)&.last
    end
    drain_output
    record_child_exit(status) if status
  rescue Errno::EIO
    status = Process.waitpid2(@child, Process::WNOHANG)&.last
    drain_output
    record_child_exit(status) if status
  ensure
    close_child_fds
    terminate_and_reap if @child
  end

  def apply_resize
    @resize_pending = false
    rows, columns = STDOUT.winsize
    raise 'invalid outer PTY geometry' unless (1..4096).cover?(rows) && (1..4096).cover?(columns)
    @writer.winsize = [rows, columns]
    record('winsize', rows: rows, columns: columns, child_pid: @child)
  rescue Errno::ENOTTY
    raise 'fixture must run on a terminal PTY'
  end

  def forward_input
    bytes = STDIN.read_nonblock(READ_LIMIT, exception: false)
    return unless bytes.is_a?(String)
    @writer.write(bytes)
    record_bytes('input', bytes)
  rescue EOFError
    @stopping = true
  end

  def forward_output
    bytes = @reader.read_nonblock(READ_LIMIT, exception: false)
    emit(bytes) if bytes.is_a?(String)
    :open
  rescue EOFError, Errno::EIO
    :closed
  end

  def drain_output
    loop do
      bytes = @reader&.read_nonblock(READ_LIMIT, exception: false)
      break unless bytes.is_a?(String)
      emit(bytes)
    end
  rescue EOFError, Errno::EIO
    nil
  end

  def emit(bytes)
    @output_bytes += bytes.bytesize
    raise "workload output exceeded #{OUTPUT_LIMIT} bytes" if @output_bytes > OUTPUT_LIMIT
    STDOUT.write(bytes)
    record_bytes('output', bytes)
    observe_workload_output(bytes)
  end

  def emit_final_marker
    if @workload == 'codex'
      @final_emitted = true
      record('final_requested', source: 'driver-final-output')
      return
    end
    return unless @workload_canaries['files_listing']
    @final_emitted = true
    emit("\r\n\e[32mTUI_STRESS_FILES_PANE_#{@pane}_FINAL\e[0m\r\n")
    record('wrapper_marker', phase: 'final')
    @stopping = true
  end

  def observe_workload_output(bytes)
    combined = @workload_tail + bytes.b
    @workload_tail = combined.bytesize > CANARY_TAIL_LIMIT ? combined.byteslice(-CANARY_TAIL_LIMIT, CANARY_TAIL_LIMIT) : combined
    case @workload
    when 'files'
      mark_workload_canary('files_listing') if @workload_tail.include?('README.md') && @workload_tail.include?("\e[")
    when 'codex'
      mark_workload_canary('codex_banner') if @workload_tail.include?('OpenAI Codex') || @workload_tail.include?('Ask Codex')
      mark_workload_canary('codex_response') if @workload_tail.include?('TUI_STRESS_RESPONSE')
    end
  end

  def mark_workload_canary(kind)
    return if @workload_canaries[kind]
    @workload_canaries[kind] = true
    record('workload_output_canary', kind: kind)
  end

  def record_bytes(kind, bytes)
    record(kind, bytes: bytes.bytesize, bytes_base64: Base64.strict_encode64(bytes))
  end

  def record(kind, values = {})
    @sequence += 1
    @events.puts(JSON.generate({ sequence: @sequence, event: kind, pane: @pane,
      host_time: Process.clock_gettime(Process::CLOCK_UPTIME_RAW) }.merge(values)))
  end

  def write_metadata
    File.write(File.join(@directory, "pane-#{@pane}.json"), JSON.generate(
      pane: @pane, wrapper_pid: Process.pid, workload: @workload, cwd: @cwd,
      output_limit: OUTPUT_LIMIT, transcript: "pane-#{@pane}-events.jsonl",
      clock_domain: 'CLOCK_UPTIME_RAW / ProcessInfo.systemUptime'
    ))
  end

  def stop_child(signal)
    return unless @child
    pid = @child
    begin
      pgid = Process.getpgid(pid)
    rescue Errno::ESRCH
      return
    end
    begin
      # Only signal a group when the child itself owns it. A stale or inherited
      # group ID is not ours to signal; the direct child signal is still owned.
      Process.kill(signal, pgid == pid ? -pid : pid)
    rescue Errno::EPERM
      record('group_signal_denied', signal: signal, child_pid: pid, child_pgid: pgid) if pgid == pid
      begin
        Process.kill(signal, pid)
      rescue Errno::ESRCH
        nil
      end
    rescue Errno::ESRCH
      nil
    end
  end

  def wait_child
    terminate_and_reap if @child
  end

  def close_child_fds
    @reader&.close unless @reader&.closed?
    @writer&.close unless @writer&.closed?
    @reader = @writer = nil
  end

  def record_child_exit(status)
    return if @child_exit_recorded
    record('child_exited', status: status_value(status))
    @child_exit_recorded = true
    @child = nil
  end

  def terminate_and_reap
    return unless @child
    # A short-lived listing can have exited after the relay's final WNOHANG
    # check. Reap first, before attempting any process-group signal.
    status = wait_for_child(0)
    unless status
      stop_child('TERM')
      status = wait_for_child(REAP_GRACE_SECONDS)
    end
    unless status
      stop_child('KILL')
      status = wait_for_child(REAP_KILL_SECONDS)
    end
    raise 'could not reap inner workload process' unless status
    record_child_exit(status)
  end

  def wait_for_child(timeout)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      status = Process.waitpid2(@child, Process::WNOHANG)&.last
      return status if status
      return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.01
    end
  rescue Errno::ECHILD
    raise 'inner workload process was reaped unexpectedly'
  end

  def write_final
    path = File.join(@directory, "pane-#{@pane}-final.json")
    payload = JSON.generate(
      pane: @pane, wrapper_pid: Process.pid, workload: @workload, output_bytes: @output_bytes,
      stopping: @stopping, child_alive: !@child.nil?, workload_canaries: @workload_canaries.keys.sort,
      failure: @failure
    )
    File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(payload) }
  end

  def status_value(status)
    { exited: status.exited?, exitstatus: status.exitstatus, signaled: status.signaled?, termsig: status.termsig }
  end
end

if ARGV == ['--self-test']
  WorkloadFixture.self_test
else
  WorkloadFixture.new.run
end
