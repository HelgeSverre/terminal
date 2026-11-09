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
        assert runner.observed_owned?(runner.pid)
        assert runner.observed_owned?(child)
        refute runner.observed_owned?(sentinel)
        refute runner.observed_owned?(nil)
        assert_empty runner.cleanup
        assert runner.observed_owned?(child), 'ownership evidence survives child exit'
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

  def test_owned_fixture_clears_inherited_color_controls_without_mutating_parent
    keys = %w[NO_COLOR CLICOLOR CLICOLOR_FORCE FORCE_COLOR]
    original = keys.to_h { |key| [key, ENV[key]] }
    keys.each_with_index { |key, index| ENV[key] = "parent-#{index}" }
    Dir.mktmpdir('terminal-smoke-environment-') do |dir|
      script = <<~'RUBY'
        keys = %w[NO_COLOR CLICOLOR CLICOLOR_FORCE FORCE_COLOR]
        puts keys.map { |key| "#{key}=#{ENV.fetch(key, '<unset>')}" }
      RUBY
      command = [RbConfig.ruby, '-e', script]
      original_command = command.dup
      default_log = File.join(dir, 'default.log')
      default = nil
      begin
        default = NativeSmokeProcess.new(command, log: default_log)
        assert default.wait(2)&.success?
        assert_empty default.cleanup
      ensure
        default&.cleanup
      end
      assert_equal original_command, command
      assert_equal keys.map { |key| "#{key}=<unset>" }, File.readlines(default_log, chomp: true)

      explicit_log = File.join(dir, 'explicit.log')
      explicit_command = [{ 'NO_COLOR' => '1' }, *command]
      original_explicit_command = explicit_command.map(&:dup)
      explicit = nil
      begin
        explicit = NativeSmokeProcess.new(explicit_command, log: explicit_log)
        assert explicit.wait(2)&.success?
        assert_empty explicit.cleanup
      ensure
        explicit&.cleanup
      end
      assert_equal original_explicit_command, explicit_command
      assert_equal 'NO_COLOR=1', File.readlines(explicit_log, chomp: true).first
      assert_equal keys.drop(1).map { |key| "#{key}=<unset>" },
        File.readlines(explicit_log, chomp: true).drop(1)
    end
    assert_equal keys.each_with_index.to_h { |key, index| [key, "parent-#{index}"] },
      keys.to_h { |key| [key, ENV[key]] }
  ensure
    original&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
