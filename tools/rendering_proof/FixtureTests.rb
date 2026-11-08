# frozen_string_literal: true

require 'json'
require 'pty'
require 'io/console'
require 'tmpdir'

Dir.mktmpdir('rendering-proof-fixture-') do |directory|
  reader, writer = PTY.open
  writer.winsize = [24, 80]
  pid = Process.spawn({ 'PATH' => '/usr/bin:/bin:/usr/sbin:/sbin', 'TERMINAL_RENDER_PROOF_DIRECTORY' => directory },
    File.join(__dir__, 'fixture.rb'), '-l', in: writer, out: writer, err: writer)
  writer.close
  received = +''
  begin
    wait = lambda do |&predicate|
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      loop do
        chunk = reader.read_nonblock(16_384, exception: false)
        received << chunk if chunk.is_a?(String)
        path = File.join(directory, 'pane-0-events.jsonl')
        rows = File.file?(path) ? File.readlines(path).filter_map { |line| JSON.parse(line) rescue nil } : []
        break if predicate.call(rows)
        raise 'Synthetic PTY fixture timed out' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.01
      end
    end
    wait.call { |events| events.any? { |e| e.values_at('rows', 'columns') == [24, 80] } }
    reader.winsize = [28, 90]
    Process.kill('WINCH', pid)
    wait.call { |events| events.any? { |e| e.values_at('rows', 'columns') == [28, 90] } }
    File.write(File.join(directory, 'final-output'), '')
    wait.call { |events| events.any? { |e| e['final'] && e['generation'] == (0x8000 | (28 << 8) | 90) } }
    raise 'Fixture output absent' unless received.include?('PANE_0')
  ensure
    Process.kill('TERM', pid) rescue Errno::ESRCH
    Process.waitpid(pid)
    reader.close
  end
end
puts 'PASS private PTY fixture: login argument, initial geometry, WINCH, final geometry barcode, child reaped'
