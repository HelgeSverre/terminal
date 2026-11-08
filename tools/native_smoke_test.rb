# frozen_string_literal: true

require 'minitest/autorun'
require 'rbconfig'
require 'tmpdir'
require_relative 'native_smoke'

class NativeSmokeProcessTest < Minitest::Test
  def test_timeout_reaps_resistant_app_and_child_without_touching_other_processes
    Dir.mktmpdir('terminal-smoke-runner-') do |dir|
      path = File.join(dir, 'child.pid')
      sentinel = Process.spawn('/bin/sleep', '30')
      runner = NativeSmokeProcess.new([RbConfig.ruby, '-e',
        'trap("TERM") {}; child = fork { trap("TERM") {}; sleep 30 }; File.write(ARGV[0], child); sleep 30', path])
      begin
        assert_nil runner.wait(0.5)
        child = Integer(File.read(path))
        assert_empty runner.cleanup
        assert_raises(Errno::ESRCH) { Process.kill(0, child) }
        Process.kill(0, sentinel)
      ensure
        runner.cleanup
        Process.kill('KILL', sentinel) rescue nil
        Process.wait(sentinel) rescue nil
      end
    end
  end

  def test_failure_status_is_preserved_and_process_is_reaped
    runner = NativeSmokeProcess.new([RbConfig.ruby, '-e', 'exit 7'])
    assert_equal 7, runner.wait(2)&.exitstatus
    assert_empty runner.cleanup
  ensure
    runner&.cleanup
  end

  def test_exited_app_does_not_hide_a_lingering_child
    runner = NativeSmokeProcess.new([RbConfig.ruby, '-e',
      'fork { sleep 30 }; sleep 0.4; exit 0'])
    assert runner.wait(2)&.success?
    refute_empty runner.live_pids
    assert_empty runner.cleanup
  ensure
    runner&.cleanup
  end
end
