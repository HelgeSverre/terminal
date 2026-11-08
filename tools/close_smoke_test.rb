# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

class CloseSmokeTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  def setup
    @paths = %w[window shortcut].map { |mode| File.join(ROOT, "reports/close-#{mode}-smoke.json") }
    @saved = @paths.to_h { |path| [path, File.exist?(path) ? File.binread(path) : nil] }
  end

  def teardown
    @saved.each do |path, bytes|
      if bytes
        File.binwrite(path, bytes)
      elsif File.exist?(path)
        File.delete(path)
      end
    end
  end

  def fixture(body)
    Dir.mktmpdir('terminal-close-runner-') do |dir|
      bundle = File.join(dir, 'Fixture.app')
      executable = File.join(bundle, 'Contents/MacOS/Terminal')
      FileUtils.mkdir_p(File.dirname(executable))
      File.write(executable, "#!#{RbConfig.ruby}\nrequire 'json'\n#{body}")
      File.chmod(0o700, executable)
      yield bundle
    end
  end

  def test_a_successful_app_exit_does_not_hide_a_surviving_child
    sentinel = Process.spawn('/bin/sleep', '30')
    fixture(<<~'RUBY') do |bundle|
      child = fork { trap('TERM') {}; sleep 30 }
      File.write(ARGV[1], JSON.generate('passed' => true, 'trigger' => 'last-window-close', 'child_pid' => child))
      sleep 0.4
    RUBY
      _, errors, status = Open3.capture3(RbConfig.ruby, File.join(ROOT, 'tools/close_smoke.rb'), bundle)
      refute status.success?
      assert_includes errors, 'PTY child survived'
      report = JSON.parse(File.read(@paths.first))
      refute report.fetch('passed')
      assert_raises(Errno::ESRCH) { Process.kill(0, report.fetch('child_pid')) }
      Process.kill(0, sentinel)
    end
  ensure
    if sentinel
      begin; Process.kill('KILL', sentinel); rescue Errno::ESRCH; end
      begin; Process.wait(sentinel); rescue Errno::ECHILD; end
    end
  end

  def test_a_report_for_the_wrong_trigger_cannot_pass
    fixture(<<~'RUBY') do |bundle|
      File.write(ARGV[1], JSON.generate('passed' => true, 'trigger' => 'cmd+q', 'child_pid' => 1))
    RUBY
      _, errors, status = Open3.capture3(RbConfig.ruby, File.join(ROOT, 'tools/close_smoke.rb'), bundle)
      refute status.success?
      assert_includes errors, 'incorrect shutdown trigger'
      report = JSON.parse(File.read(@paths.first))
      refute report.fetch('passed')
    end
  end

  def test_native_reports_gain_a_pass_only_after_both_shutdown_checks
    fixture(<<~'RUBY') do |bundle|
      child = Process.spawn('/usr/bin/true')
      Process.wait(child)
      trigger = ARGV.include?('--quit-shortcut') ? 'cmd+q' : 'last-window-close'
      File.write(ARGV[1], JSON.generate('trigger' => trigger, 'child_pid' => child))
    RUBY
      _, errors, status = Open3.capture3(RbConfig.ruby, File.join(ROOT, 'tools/close_smoke.rb'), bundle)
      assert status.success?, errors
      @paths.each do |path|
        report = JSON.parse(File.read(path))
        assert report.fetch('passed')
        assert report.fetch('app_exited')
        assert report.fetch('child_exited')
        assert_equal bundle, report.fetch('bundle_path')
      end
    end
  end
end
