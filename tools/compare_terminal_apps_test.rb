# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'compare_terminal_apps'

class TerminalAppComparisonTest < Minitest::Test
  def setup
    @comparison = TerminalAppComparison.allocate
    @comparison.instance_variable_set(:@bytes, 2 * 1_048_576)
    @comparison.instance_variable_set(:@runs, 3)
    @workload = {
      'source_bytes_per_run' => 2 * 1_048_576,
      'run_samples' => [
        { 'run' => 1, 'mib_per_second' => 2.0, 'elapsed_seconds' => 1.0, 'terminal_cpu_seconds' => 0.1 },
        { 'run' => 2, 'mib_per_second' => 8.0, 'elapsed_seconds' => 0.25, 'terminal_cpu_seconds' => 0.3 },
        { 'run' => 3, 'mib_per_second' => 4.0, 'elapsed_seconds' => 0.5, 'terminal_cpu_seconds' => 0.2 }
      ],
      'mib_per_second' => summary(4.0, 8.0),
      'elapsed_seconds' => summary(0.5, 1.0),
      'terminal_cpu_seconds' => summary(0.2, 0.3)
    }
  end

  def summary(median, maximum)
    { 'samples' => 3, 'p50' => median, 'p95' => median, 'p99' => median, 'max' => maximum }
  end

  def validate
    @comparison.send(:validate_workload, @workload, 'fixture')
  end

  def test_accepts_execution_order_observations
    validate
  end

  def test_rejects_aggregate_count_without_all_observations
    @workload['run_samples'].pop
    assert_raises(RuntimeError) { validate }
  end

  def test_rejects_duplicate_and_reordered_run_ids
    @workload['run_samples'][2]['run'] = 2
    assert_raises(RuntimeError) { validate }
    @workload['run_samples'][2]['run'] = 3
    @workload['run_samples'].reverse!
    assert_raises(RuntimeError) { validate }
  end

  def test_rejects_forged_gate_median
    @workload['mib_per_second']['p50'] = 100.0
    assert_raises(RuntimeError) { validate }
  end

  def test_rejects_independently_sorted_paired_values
    @workload['run_samples'].zip([0.25, 0.5, 1.0]).each { |sample, time| sample['elapsed_seconds'] = time }
    assert_raises(RuntimeError) { validate }
  end

  def test_accepts_unavailable_cpu_only_when_all_observations_agree
    @workload['terminal_cpu_seconds'] = nil
    @workload['run_samples'].each { |sample| sample['terminal_cpu_seconds'] = nil }
    validate
    @workload['run_samples'][0]['terminal_cpu_seconds'] = 0.1
    assert_raises(RuntimeError) { validate }
  end

  def test_rejects_nonfinite_observations
    @workload['run_samples'][0]['mib_per_second'] = Float::INFINITY
    assert_raises(RuntimeError) { validate }
  end
end
