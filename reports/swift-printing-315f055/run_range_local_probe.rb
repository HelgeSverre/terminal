#!/usr/bin/env ruby
# frozen_string_literal: true

# Reproducible runner retained with the 7fc6fac -> 315f055 range-local probe.
# It deliberately uses the frozen canonicalizer beside this file, rather than
# the parent probe (whose labels and optional WMO arguments describe 6c/6674).
#
# Usage:
#   run_range_local_probe.rb REPORT_ROOT BASELINE_7FC_BIN CANDIDATE_315_BIN

require "digest"
require "fileutils"
require "json"
require "time"

raise "usage: #{$PROGRAM_NAME} REPORT_ROOT BASELINE_7FC_BIN CANDIDATE_315_BIN" unless ARGV.length == 3

report_root, baseline_bin, candidate_bin = ARGV
require File.join(__dir__, "canonicalizer-source.rb")

WORKLOADS = %w[ascii mixed].freeze
SIDES = %w[baseline candidate].freeze
BYTES = 2 * 1024 * 1024
PAIRS = 3
TIMEOUT_SECONDS = 120.0

def sha256(path) = Digest::SHA256.file(path).hexdigest

def run_harness(root, side, binary, workload, phase, pair = nil)
  tag = [phase, workload, ("pair#{pair}" if pair), side].compact.join("-")
  log = File.join(root, "logs", "#{tag}.log")
  snapshot = File.join(root, "snapshots", "#{tag}.json")
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  pid = Process.spawn(binary, "--workload", workload, "--bytes", BYTES.to_s,
                      "--snapshot", snapshot, pgroup: true, out: log, err: "#{log}.stderr")
  status = nil
  loop do
    waited = Process.waitpid2(pid, Process::WNOHANG)
    if waited
      status = waited.last
      break
    end
    if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= started + TIMEOUT_SECONDS
      terminate_process_group(pid)
      raise "#{tag}: timeout after #{TIMEOUT_SECONDS}s"
    end
    sleep 0.025
  end
  stderr = File.exist?("#{log}.stderr") ? File.read("#{log}.stderr") : ""
  raise "#{tag}: exit #{status.exitstatus}: #{stderr}" unless status.success?
  record = JSON.parse(File.read(log).strip)
  raise "#{tag}: unsupported driver protocol" unless record["protocol"] == 1
  raise "#{tag}: missing final snapshot" unless File.file?(snapshot)
  record.merge("implementation" => side, "phase" => phase, "pair" => pair,
               "wall_ns" => ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000_000_000).round,
               "snapshot_path" => snapshot, "snapshot_sha256" => sha256(snapshot))
end

def stream_gate(samples)
  failures = []
  WORKLOADS.each do |workload|
    fields = %w[payload_bytes payload_fnv1a64 reply_bytes reply_fnv1a64]
    values = SIDES.to_h do |side|
      records = samples.select { |sample| sample["workload"] == workload && sample["implementation"] == side }
      failures << "#{workload}/#{side}: expected #{PAIRS} samples, got #{records.length}" unless records.length == PAIRS
      [side, records.map { |record| fields.map { |field| record.fetch(field) } }.uniq]
    end
    failures << "#{workload}: payload/reply stream mismatch #{values.inspect}" unless values.values.flatten(1).uniq.length == 1
  end
  { "passed" => failures.empty?, "failures" => failures }
end

def snapshot_gate(root, samples)
  mismatches = []
  FileUtils.mkdir_p(File.join(root, "canonical"))
  WORKLOADS.each do |workload|
    PAIRS.times do |index|
      hashes = SIDES.to_h do |side|
        sample = samples.find { |item| item["workload"] == workload && item["implementation"] == side && item["pair"] == index + 1 }
        raw, projection = normalize_snapshot(File.read(sample.fetch("snapshot_path")))
        text = canonical_json(projection)
        path = File.join(root, "canonical", "#{workload}-pair#{index + 1}-#{side}.json")
        File.write(path, text + "\n")
        [side, { "raw_sha256" => Digest::SHA256.hexdigest(JSON.generate(raw)), "canonical_sha256" => Digest::SHA256.hexdigest(text), "path" => path }]
      end
      mismatches << { "workload" => workload, "pair" => index + 1, "states" => hashes } unless hashes.values.map { |item| item.fetch("canonical_sha256") }.uniq.length == 1
    end
  end
  { "passed" => mismatches.empty?, "mismatches" => mismatches }
end

FileUtils.mkdir_p(File.join(report_root, "logs"))
FileUtils.mkdir_p(File.join(report_root, "snapshots"))
result = {
  "protocol" => 1,
  "contract" => {
    "labels" => { "baseline" => "Swift 7fc6fac -O", "candidate" => "Swift 315f055 -O" },
    "geometry" => [160, 50], "history_rows" => 0, "workloads" => WORKLOADS,
    "requested_bytes" => BYTES, "max_feed_span" => 64 * 1024,
    "warmup_per_implementation" => 1, "alternating_pairs" => PAIRS,
    "timed_operations" => "feed, reply drain, pending-work drain, finish, reply drain, invariant validation, snapshot serialization/copy/free"
  },
  "binaries" => SIDES.to_h { |side|
    binary = side == "baseline" ? baseline_bin : candidate_bin
    [side, { "path" => File.realpath(binary), "sha256" => sha256(binary), "bytes" => File.size(binary) }]
  },
  "hardware" => hardware, "background_at_start" => background_activity,
  "warmups" => [], "samples" => []
}

begin
  WORKLOADS.each do |workload|
    SIDES.each { |side| result["warmups"] << run_harness(report_root, side, side == "baseline" ? baseline_bin : candidate_bin, workload, "warmup") }
    PAIRS.times do |index|
      (index.even? ? SIDES : SIDES.reverse).each do |side|
        result["samples"] << run_harness(report_root, side, side == "baseline" ? baseline_bin : candidate_bin, workload, "sample", index + 1)
      end
    end
  end
  result["replay_gate"] = stream_gate(result.fetch("samples"))
  result["snapshot_gate"] = snapshot_gate(report_root, result.fetch("samples"))
  raise "correctness gate failed" unless result.dig("replay_gate", "passed") && result.dig("snapshot_gate", "passed")
  result["status"] = "complete"
rescue StandardError => error
  result["status"] = "incomplete"
  result["failure"] = { "class" => error.class.name, "message" => error.message }
  raise
ensure
  result["finished_at_utc"] = Time.now.utc.iso8601
  File.write(File.join(report_root, "result.json"), JSON.pretty_generate(result) + "\n")
end
