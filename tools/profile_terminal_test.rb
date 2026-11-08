# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'tmpdir'
require_relative 'profile_terminal'

class ProfileTerminalTest < Minitest::Test
  def test_cleanup_survivor_makes_a_completed_profile_fail
    Dir.mktmpdir('terminal-profile-cleanup-') do |root|
      sample = FakeOwnedProcess.new(survivors: [4242])
      app = FakeOwnedProcess.new
      profile = CleanupFixtureProfile.new(File.join(root, 'profile'), sample:, app:)

      error = assert_raises(TerminalAppProfile::CleanupFailure) { profile.run }
      assert_includes error.message, 'sample survivors: 4242'
      assert_equal 1, sample.cleanup_calls
      assert_equal 1, app.cleanup_calls

      report = JSON.parse(File.read(File.join(root, 'profile', 'profile.json')))
      refute report.fetch('passed')
      assert_includes report.fetch('failure'), 'sample survivors: 4242'
      assert_equal [4242], report.dig('lifecycle', 'sample', 'cleanup_survivors')
    end
  end

  def test_app_cleanup_runs_after_sample_cleanup_error
    Dir.mktmpdir('terminal-profile-cleanup-') do |root|
      sample = FakeOwnedProcess.new(cleanup_error: 'sample cleanup broke')
      app = FakeOwnedProcess.new
      profile = CleanupFixtureProfile.new(File.join(root, 'profile'), sample:, app:)

      error = assert_raises(TerminalAppProfile::CleanupFailure) { profile.run }
      assert_includes error.message, 'sample cleanup error: RuntimeError: sample cleanup broke'
      assert_equal 1, sample.cleanup_calls
      assert_equal 1, app.cleanup_calls

      report = JSON.parse(File.read(File.join(root, 'profile', 'profile.json')))
      refute report.fetch('passed')
      assert_includes report.dig('lifecycle', 'sample', 'cleanup_error'), 'sample cleanup broke'
    end
  end

  class CleanupFixtureProfile < TerminalAppProfile
    def initialize(output, sample:, app:)
      @output = output
      @sample_process = sample
      @app_process = app
      @result = {
        'passed' => false,
        'lifecycle' => {
          'sample' => { 'pid' => sample.pid, 'natural_exit' => false },
          'app' => { 'pid' => app.pid, 'natural_exit' => false }
        }
      }
    end

    private

    def build_driver; end
    def run_profile; end
  end

  class FakeOwnedProcess
    attr_reader :pid, :status, :cleanup_calls

    def initialize(survivors: [], cleanup_error: nil)
      @pid = 101
      @survivors = survivors
      @cleanup_error = cleanup_error
      @cleanup_calls = 0
      @status = nil
    end

    def live_pids = @survivors

    def cleanup
      @cleanup_calls += 1
      raise @cleanup_error if @cleanup_error

      @survivors
    end
  end
end
