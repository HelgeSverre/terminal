#!/usr/bin/env ruby
# frozen_string_literal: true

# Controlled runner for tools/EmulatorComparison.c linked separately to frozen
# Swift and Rust core executables. It makes no builds and launches no GUI.

require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "time"
require "tmpdir"

class ComparisonError < StandardError; end

DEFAULT_BYTES = 32 * 1024 * 1024
WORKLOADS = %w[ascii mixed].freeze
VOLATILE_ROOT_FIELDS = %w[
  revision geometry_epoch document_epoch history_epoch screen_epoch
  viewport_clamp_revision history
].freeze
SWIFT_ONLY_GEOMETRY_FIELDS = %w[
  primary_margins alternate_margins vertical_margins
].freeze

def command_output(*command)
  output, status = Open3.capture2e(*command)
  raise ComparisonError, "#{command.join(' ')} failed: #{output}" unless status.success?

  output.strip
end

def sha256(path)
  Digest::SHA256.file(path).hexdigest
end

def command_optional(*command)
  output, = Open3.capture2e(*command)
  output.strip
rescue Errno::ENOENT
  nil
end

def rss_kb(pid)
  text = command_optional("/bin/ps", "-o", "rss=", "-p", pid.to_s)
  value = text.to_s.strip
  value.match?(/\A\d+\z/) ? value.to_i : nil
end

def terminate_process_group(pid)
  begin
    Process.kill("TERM", -pid)
  rescue Errno::ESRCH
    return
  end
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2.0
  begin
    loop do
      return if Process.waitpid(pid, Process::WNOHANG)
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.02
    end
    begin
      Process.kill("KILL", -pid)
    rescue Errno::ESRCH
      return
    end
    Process.waitpid(pid)
  rescue Errno::ECHILD
    nil
  end
end

def run_harness(executable:, workload:, bytes:, snapshot_path:, log_path:, timeout_seconds:, on_spawn: nil)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  deadline = started + timeout_seconds
  pid = Process.spawn(executable, "--workload", workload, "--bytes", bytes.to_s,
                      "--snapshot", snapshot_path, pgroup: true, out: log_path,
                      err: "#{log_path}.stderr")
  on_spawn&.call(pid)
  samples = []
  status = nil
  timed_out = false
  begin
    loop do
      value = rss_kb(pid)
      samples << value if value
      waited = Process.waitpid2(pid, Process::WNOHANG)
      if waited
        status = waited.last
        break
      end
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        timed_out = true
        terminate_process_group(pid)
        raise ComparisonError, "harness timed out after #{timeout_seconds} seconds: #{executable}"
      end
      sleep 0.025
    end
  ensure
    terminate_process_group(pid) if status.nil? && !timed_out
  end
  wall_ns = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000_000_000).round
  output = File.read(log_path).strip
  stderr = File.exist?("#{log_path}.stderr") ? File.read("#{log_path}.stderr") : ""
  raise ComparisonError, "#{executable} exited #{status.exitstatus}: #{stderr}" unless status.success?

  record = JSON.parse(output)
  raise ComparisonError, "#{executable} emitted an unsupported harness protocol" unless record["protocol"] == 1
  raise ComparisonError, "#{executable} did not create #{snapshot_path}" unless File.file?(snapshot_path)
  record.merge(
    "wall_ns" => wall_ns,
    "rss_samples_kb" => samples,
    "rss_last_kb" => samples.last,
    "rss_peak_kb" => samples.max,
    "rss_scope" => "direct child; includes the allocated replay corpus and runtime allocations",
    "snapshot_sha256" => sha256(snapshot_path),
    "snapshot_path" => snapshot_path
  )
rescue JSON::ParserError => error
  raise ComparisonError, "#{executable} did not emit one JSON result: #{error}; stderr: #{stderr}"
end

def assert_current_frozen_source!(root, provenance)
  root = File.realpath(root)
  expected = provenance.fetch("source_commit")
  actual = command_output("git", "-C", root, "rev-parse", "HEAD")
  raise ComparisonError, "source commit changed for #{root}: #{actual}, expected #{expected}" unless actual == expected
  dirty = command_output("git", "-C", root, "status", "--porcelain")
  raise ComparisonError, "source worktree is not frozen/clean: #{root}" unless dirty.empty?
  raise ComparisonError, "provenance did not attest a clean source tree" unless provenance["source_tree_clean"] == true
end

def load_provenance(path, implementation, executable, root)
  provenance = JSON.parse(File.read(path))
  required = %w[implementation source_root source_commit source_tree_clean executable_sha256 compiler build_wall_seconds build_command]
  missing = required.reject { |key| provenance.key?(key) }
  raise ComparisonError, "#{path} lacks #{missing.join(', ')}" unless missing.empty?
  raise ComparisonError, "#{path} describes #{provenance['implementation']}, not #{implementation}" unless provenance["implementation"] == implementation
  raise ComparisonError, "frozen binary hash mismatch for #{executable}" unless provenance["executable_sha256"] == sha256(executable)
  raise ComparisonError, "provenance source root does not match #{root}" unless File.realpath(provenance["source_root"]) == File.realpath(root)
  assert_current_frozen_source!(root, provenance)
  provenance.merge("executable" => File.realpath(executable), "executable_bytes" => File.size(executable),
                   "provenance_path" => File.realpath(path))
end

def normalize_snapshot(raw)
  value = JSON.parse(raw)
  raise ComparisonError, "snapshot root is not an object" unless value.is_a?(Hash)
  raise ComparisonError, "snapshot does not publish boolean input_ready" unless [true, false].include?(value["input_ready"])
  canonical = Marshal.load(Marshal.dump(value))
  VOLATILE_ROOT_FIELDS.each { |key| canonical.delete(key) }
  # These per-row IDs/revisions are implementation-local allocation/publication
  # identities, not terminal-visible cells. The raw snapshots remain saved.
  Array(canonical["rows"]).each do |row|
    row.delete("id")
    row.delete("revision")
  end
  # Rust ABI v1 JSON predates the three Swift-only document-margin observations.
  # The published corpus never changes horizontal/vertical margins; a dedicated
  # margin fixture must compare them once Rust exposes counterpart fields.
  SWIFT_ONLY_GEOMETRY_FIELDS.each { |key| canonical.delete(key) }
  [value, canonical]
rescue JSON::ParserError => error
  raise ComparisonError, "snapshot JSON invalid: #{error}"
end

def canonical_json(value)
  JSON.generate(sort_json(value))
end

def sort_json(value)
  case value
  when Hash then value.keys.sort.each_with_object({}) { |key, out| out[key] = sort_json(value[key]) }
  when Array then value.map { |item| sort_json(item) }
  else value
  end
end

def median(values)
  ordered = values.sort
  middle = ordered.length / 2
  ordered.length.odd? ? ordered[middle] : (ordered[middle - 1] + ordered[middle]) / 2.0
end

def throughput_mib_s(record)
  record.fetch("payload_bytes") / (1024.0 * 1024.0) / (record.fetch("elapsed_ns") / 1_000_000_000.0)
end

def hardware
  {
    "os_product_version" => command_optional("/usr/bin/sw_vers", "-productVersion"),
    "kernel" => command_optional("/usr/bin/uname", "-a"),
    "model" => command_optional("/usr/sbin/sysctl", "-n", "hw.model"),
    "cpu" => command_optional("/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"),
    "logical_cpus" => command_optional("/usr/sbin/sysctl", "-n", "hw.logicalcpu"),
    "power" => command_optional("/usr/bin/pmset", "-g", "batt")
  }
end

def background_activity
  processes = command_optional("/bin/ps", "-axo", "pcpu=,comm=").to_s.lines.filter_map do |line|
    percent, command = line.strip.split(/\s+/, 2)
    next unless command && percent.match?(/\A\d+(?:\.\d+)?\z/)

    { "name" => File.basename(command), "cpu_percent" => percent.to_f }
  end
  {
    "observed_at_utc" => Time.now.utc.iso8601,
    "load_average" => command_optional("/usr/sbin/sysctl", "-n", "vm.loadavg"),
    "top_processes" => processes.sort_by { |entry| -entry.fetch("cpu_percent") }.first(8)
  }
end

def self_test!
  true_snapshot = normalize_snapshot(JSON.generate("input_ready" => true, "rows" => [])).last
  false_snapshot = normalize_snapshot(JSON.generate("input_ready" => false, "rows" => [])).last
  raise "input_ready was incorrectly projected away" if canonical_json(true_snapshot) == canonical_json(false_snapshot)

  Dir.mktmpdir("emulator-comparison-self-test") do |directory|
    executable = File.join(directory, "hang")
    File.write(executable, "#!/bin/sh\nsleep 30\n")
    File.chmod(0o755, executable)
    child_pid = nil
    begin
      run_harness(executable: executable, workload: "ascii", bytes: 1,
                  snapshot_path: File.join(directory, "snapshot.json"),
                  log_path: File.join(directory, "hang.log"), timeout_seconds: 0.1,
                  on_spawn: ->(pid) { child_pid = pid })
      raise "watchdog did not fire"
    rescue ComparisonError => error
      raise error unless error.message.include?("timed out")
    end
    raise "watchdog child was never spawned" unless child_pid
    begin
      Process.kill(0, child_pid)
      raise "timed-out child still exists"
    rescue Errno::ESRCH
      # Expected: the owned process group was reaped.
    end
  end
  puts "compare_emulators self-test: PASS"
end

if $PROGRAM_NAME == __FILE__
  if ARGV == ["--self-test"]
    self_test!
    exit
  end

options = { bytes: DEFAULT_BYTES, warmup: 1, pairs: 3, samples_per_turn: 5, timeout_seconds: 120.0 }
parser = OptionParser.new do |opts|
  opts.banner = "usage: ruby tools/compare_emulators.rb [options]"
  opts.on("--swift-bin PATH") { |value| options[:swift_bin] = value }
  opts.on("--rust-bin PATH") { |value| options[:rust_bin] = value }
  opts.on("--swift-root PATH") { |value| options[:swift_root] = value }
  opts.on("--rust-root PATH") { |value| options[:rust_root] = value }
  opts.on("--swift-provenance PATH") { |value| options[:swift_provenance] = value }
  opts.on("--rust-provenance PATH") { |value| options[:rust_provenance] = value }
  opts.on("--output PATH") { |value| options[:output] = value }
  opts.on("--bytes N", Integer) { |value| options[:bytes] = value }
  opts.on("--warmup N", Integer) { |value| options[:warmup] = value }
  opts.on("--pairs N", Integer) { |value| options[:pairs] = value }
  opts.on("--samples-per-turn N", Integer) { |value| options[:samples_per_turn] = value }
  opts.on("--timeout-seconds N", Float) { |value| options[:timeout_seconds] = value }
end
parser.parse!
required = %i[swift_bin rust_bin swift_root rust_root swift_provenance rust_provenance output]
missing = required.reject { |key| options[key] }
abort(parser.to_s + "\nmissing: #{missing.join(', ')}") unless missing.empty?
raise ComparisonError, "bytes, warmup, pairs, samples-per-turn and timeout must be positive" unless
  [options[:bytes], options[:warmup], options[:pairs], options[:samples_per_turn], options[:timeout_seconds]].all?(&:positive?)
raise ComparisonError, "refusing to overwrite existing output #{options[:output]}" if File.exist?(options[:output])
%i[swift_bin rust_bin swift_provenance rust_provenance].each do |key|
  raise ComparisonError, "missing #{key}: #{options[key]}" unless File.file?(options[key])
end
raise ComparisonError, "Swift harness is not executable" unless File.executable?(options[:swift_bin])
raise ComparisonError, "Rust harness is not executable" unless File.executable?(options[:rust_bin])

FileUtils.mkdir_p(options[:output])
snapshots = File.join(options[:output], "snapshots")
FileUtils.mkdir_p(snapshots)
implementations = {
  "swift" => load_provenance(options[:swift_provenance], "swift", options[:swift_bin], options[:swift_root]),
  "rust" => load_provenance(options[:rust_provenance], "rust", options[:rust_bin], options[:rust_root])
}
result = {
  "protocol" => 1,
  "orchestrator_sha256" => sha256(__FILE__),
  "started_at_utc" => Time.now.utc.iso8601,
  "contract" => {
    "geometry" => [160, 50], "history_rows" => 0, "workloads" => WORKLOADS,
    "requested_bytes" => options[:bytes], "warmup_per_implementation" => options[:warmup],
    "alternating_pairs" => options[:pairs], "samples_per_turn" => options[:samples_per_turn],
    "timeout_seconds_per_harness" => options[:timeout_seconds],
    "timed_operations" => "feed, reply drain, pending-work drain, finish, reply drain, invariant validation, snapshot serialization/copy/free",
    "not_measured" => "GUI, renderer, PTY, process creation, corpus construction and result file I/O"
  },
  "hardware" => hardware,
  "background_at_start" => background_activity,
  "implementations" => implementations,
  "warmups" => [], "samples" => [], "snapshot_gate" => { "passed" => true, "mismatches" => [] }
}

begin
  WORKLOADS.each do |workload|
    %w[swift rust].each do |implementation|
      options[:warmup].times do |index|
        prefix = "warmup-#{workload}-#{implementation}-#{index + 1}"
        result["warmups"] << run_harness(executable: implementations.fetch(implementation).fetch("executable"), workload: workload,
          bytes: options[:bytes], snapshot_path: File.join(snapshots, "#{prefix}.json"), log_path: File.join(options[:output], "#{prefix}.log"),
          timeout_seconds: options[:timeout_seconds])
      end
    end
    options[:pairs].times do |pair|
      order = pair.even? ? %w[swift rust] : %w[rust swift]
      order.each do |implementation|
        options[:samples_per_turn].times do |sample|
          prefix = "#{workload}-pair#{pair + 1}-#{implementation}-#{sample + 1}"
          record = run_harness(executable: implementations.fetch(implementation).fetch("executable"), workload: workload,
            bytes: options[:bytes], snapshot_path: File.join(snapshots, "#{prefix}.json"), log_path: File.join(options[:output], "#{prefix}.log"),
            timeout_seconds: options[:timeout_seconds])
          record["implementation"] = implementation
          record["pair"] = pair + 1
          record["sample"] = sample + 1
          result["samples"] << record
        end
      end
    end
  end

  WORKLOADS.each do |workload|
    by_impl = result["samples"].select { |sample| sample["workload"] == workload }.group_by { |sample| sample["implementation"] }
    swift = by_impl.fetch("swift")
    rust = by_impl.fetch("rust")
    swift.zip(rust).each_with_index do |(swift_sample, rust_sample), index|
      swift_raw, swift_canonical = normalize_snapshot(File.read(swift_sample.fetch("snapshot_path")))
      rust_raw, rust_canonical = normalize_snapshot(File.read(rust_sample.fetch("snapshot_path")))
      next if canonical_json(swift_canonical) == canonical_json(rust_canonical)

      result["snapshot_gate"]["passed"] = false
      result["snapshot_gate"]["mismatches"] << {
        "workload" => workload, "sample_index" => index + 1,
        "swift_snapshot_sha256" => Digest::SHA256.hexdigest(JSON.generate(swift_raw)),
        "rust_snapshot_sha256" => Digest::SHA256.hexdigest(JSON.generate(rust_raw)),
        "swift_canonical_sha256" => Digest::SHA256.hexdigest(canonical_json(swift_canonical)),
        "rust_canonical_sha256" => Digest::SHA256.hexdigest(canonical_json(rust_canonical))
      }
    end
  end
  result["status"] = "complete"
rescue Exception => error # Interrupted runs must retain an auditable incomplete report.
  result["status"] = "incomplete"
  result["failure"] = { "class" => error.class.name, "message" => error.message }
  raise
ensure
  result["finished_at_utc"] = Time.now.utc.iso8601
  File.write(File.join(options[:output], "result.json"), JSON.pretty_generate(result) + "\n")
end

rows = WORKLOADS.map do |workload|
  values = %w[swift rust].to_h do |implementation|
    samples = result["samples"].select { |item| item["workload"] == workload && item["implementation"] == implementation }
    [implementation, samples.empty? ? nil : median(samples.map { |item| throughput_mib_s(item) })]
  end
  "| #{workload} | #{format('%.2f', values['swift'])} | #{format('%.2f', values['rust'])} |"
end
build_rows = %w[swift rust].map do |implementation|
  item = implementations.fetch(implementation)
  "| #{implementation} | #{item['build_wall_seconds']} | #{item['executable_bytes']} | #{item['executable_sha256']} |"
end
File.write(File.join(options[:output], "summary.md"), <<~MARKDOWN)
  # Frozen Swift vs Rust core comparison

  Canonical final-snapshot gate: **#{result.dig('snapshot_gate', 'passed') ? 'PASS' : 'FAIL'}**. No speed winner is asserted by this report.

  | Implementation | Frozen build wall seconds | Executable bytes | SHA-256 |
  | --- | ---: | ---: | --- |
  #{build_rows.join("\n")}

  | Workload | Swift median MiB/s | Rust median MiB/s |
  | --- | ---: | ---: |
  #{rows.join("\n")}

  See `result.json` for every runtime/RSS sample and `snapshots/` for every raw final ABI JSON snapshot.
MARKDOWN

abort "canonical final snapshots differ; see #{options[:output]}/result.json" unless result.dig("snapshot_gate", "passed")
end
