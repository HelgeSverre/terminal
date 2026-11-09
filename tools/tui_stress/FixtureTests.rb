#!/usr/bin/env ruby
# frozen_string_literal: true

require 'base64'
require 'io/console'
require 'json'
require 'pty'
require 'tmpdir'

fixture = File.join(__dir__, 'fixture.rb')
Dir.mktmpdir('terminal-tui-stress-fixture-') do |directory|
  cwd = File.join(directory, 'cwd')
  Dir.mkdir(cwd)
  binary = File.join(directory, 'files-fixture')
  File.write(binary, <<~RUBY)
    #!/usr/bin/env ruby
    require 'io/console'
    trap('WINCH') do
      rows, columns = STDOUT.winsize
      STDOUT.write(" CHILD_RESIZE=\#{columns}x\#{rows}")
      STDOUT.flush
    end
    payload = "\\e[38;2;1;2;3m猫 FILES_FIXTURE README.md\\e[0m".b
    payload.each_byte { |byte| STDOUT.write(byte.chr); STDOUT.flush; sleep 0.001 }
    sleep 0.75
  RUBY
  File.chmod(0o700, binary)
  reader, writer = PTY.open
  writer.winsize = [21, 71]
  environment = {
    'TERMINAL_TUI_STRESS_DIRECTORY' => directory,
    'TERMINAL_TUI_STRESS_WORKLOAD' => 'files',
    'TERMINAL_TUI_STRESS_CWD' => cwd,
    'TERMINAL_TUI_STRESS_FILES' => binary,
    'PATH' => '/usr/bin:/bin:/usr/sbin:/sbin',
  }
  error_reader, error_writer = IO.pipe
  pid = Process.spawn(environment, fixture, '-l', in: writer, out: writer, err: error_writer)
  writer.close
  error_writer.close
  wrapper_status = nil
  wait_for_wrapper = lambda do |seconds|
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    loop do
      result = Process.waitpid2(pid, Process::WNOHANG)
      return result.last if result
      return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.01
    end
  rescue Errno::ECHILD
    nil
  end
  output = +''
  read = lambda do
    chunk = reader.read_nonblock(16_384, exception: false)
    output << chunk if chunk.is_a?(String)
  end
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 4
  begin
    until File.file?(File.join(directory, 'pane-0-events.jsonl')) && output.include?('FILES_FIXTURE')
      read.call
      raise "fixture startup timeout: #{output.inspect}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.01
    end
    reader.winsize = [24, 79]
    Process.kill('WINCH', pid)
    events = []
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    until events.any? { |event| event['event'] == 'winsize' && event['rows'] == 24 && event['columns'] == 79 } && output.include?('CHILD_RESIZE=79x24')
      read.call
      events = File.readlines(File.join(directory, 'pane-0-events.jsonl')).map { |line| JSON.parse(line) }
      raise "fixture resize relay/child timeout: output=#{output.inspect}, events=#{events.last(8).inspect}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.01
    end
    File.write(File.join(directory, 'final-output'), '')
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    until events.any? { |event| event['event'] == 'wrapper_marker' && event['phase'] == 'final' }
      read.call
      events = File.readlines(File.join(directory, 'pane-0-events.jsonl')).map { |line| JSON.parse(line) }
      raise "fixture final marker timeout: #{events.last(8).inspect}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.01
    end
    transcript = events.select { |event| event['event'] == 'output' }
      .map { |event| Base64.strict_decode64(event.fetch('bytes_base64')) }.join
    raise 'unicode output was not preserved' unless transcript.force_encoding(Encoding::UTF_8).include?('猫 FILES_FIXTURE')
    raise 'final marker was not preserved' unless transcript.include?('TUI_STRESS_FILES_PANE_0_FINAL')
    raise 'missing real child lifecycle' unless events.any? { |event| event['event'] == 'child_started' }
    raise 'missing genuine listing canary' unless events.any? { |event| event['event'] == 'workload_output_canary' && event['kind'] == 'files_listing' }
    raise 'fixture events omitted uptime host time' unless events.all? { |event| event['host_time'].is_a?(Numeric) && !event.key?('monotonic') }
    wrapper_status = wait_for_wrapper.call(1)
    unless wrapper_status
      Process.kill('TERM', pid) rescue Errno::ESRCH
      wrapper_status = wait_for_wrapper.call(3)
    end
    stderr_tail = error_reader.read.byteslice(-4096, 4096)
    raise "fixture wrapper did not exit: stderr=#{stderr_tail.inspect}" unless wrapper_status
    raise "fixture wrapper failed: #{wrapper_status.inspect}, stderr=#{stderr_tail.inspect}" unless wrapper_status.success?
  ensure
    unless wrapper_status
      Process.kill('TERM', pid) rescue Errno::ESRCH
      wrapper_status = wait_for_wrapper.call(3)
    end
    reader.close
    error_reader.close
  end
  final_path = File.join(directory, 'pane-0-final.json')
  raise "fixture final receipt missing: status=#{wrapper_status.inspect}" unless File.file?(final_path)
  metadata = JSON.parse(File.read(File.join(directory, 'pane-0.json')))
  raise 'fixture clock domain metadata mismatch' unless metadata['clock_domain'] == 'CLOCK_UPTIME_RAW / ProcessInfo.systemUptime'
  final = JSON.parse(File.read(final_path))
  raise 'fixture cleanup receipt failed' unless final['stopping'] && final['child_alive'] == false && final['failure'].nil?

  linger = File.join(directory, 'closed-tty-linger')
  File.write(linger, <<~RUBY)
    #!/usr/bin/env ruby
    trap('TERM') {}
    trap('HUP') {}
    File.write(ENV.fetch('TUI_STRESS_LINGER_READY'), '')
    STDIN.close
    STDOUT.close
    STDERR.close
    loop { sleep 1 }
  RUBY
  File.chmod(0o700, linger)
  linger_reader, linger_writer = PTY.open
  linger_writer.winsize = [18, 62]
  linger_ready = File.join(directory, 'closed-tty-linger-ready')
  linger_environment = environment.merge('TERMINAL_TUI_STRESS_FILES' => linger, 'TUI_STRESS_LINGER_READY' => linger_ready)
  linger_pid = Process.spawn(linger_environment, fixture, '-l', in: linger_writer, out: linger_writer, err: linger_writer)
  linger_writer.close
  begin
    linger_events = File.join(directory, 'pane-1-events.jsonl')
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 4
    events = []
    until events.any? { |event| event['event'] == 'child_started' } && File.file?(linger_ready)
      events = File.file?(linger_events) ? File.readlines(linger_events).map { |line| JSON.parse(line) } : []
      raise 'closed-TTY child did not start' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.02
    end
    Process.kill('TERM', linger_pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    loop do
      break if Process.waitpid2(linger_pid, Process::WNOHANG)
      raise 'fixture wrapper did not exit after TERM' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.02
    end
    events = File.readlines(linger_events).map { |line| JSON.parse(line) }
    raise "closed-TTY child was not force-reaped: #{events.last(8).inspect}" unless events.any? do |event|
      event['event'] == 'child_exited' && event.dig('status', 'signaled') && event.dig('status', 'termsig') == 9
    end
  ensure
    Process.kill('TERM', linger_pid) rescue Errno::ESRCH
    Process.waitpid(linger_pid) rescue Errno::ECHILD
    linger_reader.close
  end
  linger_final = JSON.parse(File.read(File.join(directory, 'pane-1-final.json')))
  raise 'lingering child cleanup receipt failed' unless linger_final['stopping'] && linger_final['child_alive'] == false && linger_final['failure'].nil?
end
puts 'PASS tui-stress fixture: real inner command, Unicode transcript, WINCH relay and forced child cleanup'
