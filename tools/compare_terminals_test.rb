# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'tmpdir'
require_relative 'compare_terminals'

class TerminalComparisonTest < Minitest::Test
  class FixtureProcess
    attr_accessor :interrupt_on_pid, :exit_success, :on_wait, :command
    attr_reader :cleaned
    def initialize = @exit_success = true
    def pid
      raise Interrupt, 'after launch' if @interrupt_on_pid
      123
    end
    def wait(_seconds)
      on_wait&.call
      Struct.new(:success?).new(@exit_success)
    end
    def live_pids = []
    def observed_owned?(pid) = pid == 123
    def cleanup
      @cleaned = true
      []
    end
  end

  def trial(process, report: nil, failed: nil, name: 'ghostty')
    Dir.mktmpdir('ghostty-comparison-test-') do |directory|
      subject = TerminalComparison.allocate
      subject.instance_variable_set(:@output, directory)
      subject.instance_variable_set(:@bytes, 1)
      subject.instance_variable_set(:@runs, 1)
      path = File.join(directory, "1-#{name}.json")
      process.on_wait = lambda do
        File.write(path, JSON.generate(report)) if report
        File.write("#{path}.failed", failed) if failed
      end
      original = NativeSmokeProcess.method(:new)
      begin
        NativeSmokeProcess.define_singleton_method(:new) { |command, **_options| process.command = command; process }
        subject.send(:measure, name, "/fixture/#{name}", '/fixture/driver', '/fixture/config', 1, { 'apps' => {} })
      ensure
        NativeSmokeProcess.define_singleton_method(:new, original)
      end
    end
  end

  def report
    { 'schema' => 2, 'terminal' => 'ghostty', 'terminal_pid' => 123,
      'columns' => 100, 'rows' => 30, 'pixel_width' => 800, 'pixel_height' => 540,
      'output_post_processing' => true,
      'workloads' => %w[ascii_short_lines ascii_long_lines ansi_truecolor unicode].map do |name|
        { 'name' => name, 'source_bytes_per_run' => 1,
          'run_samples' => [{ 'run' => 1, 'mib_per_second' => 1.0 }],
          'mib_per_second' => { 'p50' => 1.0 } }
      end }
  end

  def test_interrupt_after_launch_still_cleans_up
    process = FixtureProcess.new
    process.interrupt_on_pid = true
    assert_raises(Interrupt) { trial(process) }
    assert process.cleaned
  end

  def test_driver_failure_is_retained_even_when_app_exits_nonzero
    process = FixtureProcess.new
    process.exit_success = false
    error = assert_raises(RuntimeError) { trial(process, failed: 'geometry is 100x27; expected 100x30') }
    assert_equal 'geometry is 100x27; expected 100x30', error.message
    assert process.cleaned
  end

  def test_bad_label_and_missing_mode_are_rejected
    [{ 'terminal' => 'another-app' }, { 'output_post_processing' => nil }].each do |change|
      process = FixtureProcess.new
      assert_raises(RuntimeError) { trial(process, report: report.merge(change)) }
      assert process.cleaned
    end
  end

  def test_valid_owned_report_is_accepted_and_cleaned
    process = FixtureProcess.new
    trial(process, report: report)
    assert process.cleaned
  end

  def test_kitty_uses_an_isolated_grid_and_quits_with_its_window
    process = FixtureProcess.new
    trial(process, name: 'kitty', report: report.merge('terminal' => 'kitty'))
    assert_equal %w[/fixture/kitty --config NONE --session none], process.command.first(5)
    %w[initial_window_width=100c initial_window_height=30c shell_integration=disabled
       macos_quit_when_last_window_closed=yes].each { |option| assert_includes process.command, option }
    assert process.cleaned
  end
end
