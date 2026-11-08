# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'

abort 'Usage: compare_swift_rows.rb BASE_REVISION CANDIDATE_REVISION NEW_REPORT_DIRECTORY' unless ARGV.length == 3
baseline, candidate, destination = ARGV
output = File.expand_path(destination)
abort 'Choose a new report directory' if File.exist?(output)
FileUtils.mkdir_p(output)
fixture = File.expand_path('RowStorageCompatibilityProbe.swift', __dir__)
FileUtils.cp(fixture, "#{output}/probe.swift")
FileUtils.cp(__FILE__, "#{output}/runner.rb")
fixture = "#{output}/probe.swift"
result = { 'passed' => false, 'fixture_sha256' => Digest::SHA256.file(fixture).hexdigest,
           'runner_sha256' => Digest::SHA256.file("#{output}/runner.rb").hexdigest, 'revisions' => {} }

def run_capture(command, log)
  stdout, stderr, status = Open3.capture3(*command)
  File.write(log, stderr)
  raise "Command failed (#{status.exitstatus}): #{command.first}; see #{log}" unless status.success?

  stdout
end

def first_difference(left, right, path = '$')
  if left.is_a?(Hash) && right.is_a?(Hash)
    return [path, left.keys.sort, right.keys.sort] unless left.keys.sort == right.keys.sort
    left.each_key do |key|
      difference = first_difference(left[key], right[key], "#{path}.#{key}")
      return difference if difference
    end
  elsif left.is_a?(Array) && right.is_a?(Array)
    return ["#{path}.length", left.length, right.length] unless left.length == right.length
    left.each_index do |index|
      difference = first_difference(left[index], right[index], "#{path}[#{index}]")
      return difference if difference
    end
  elsif left != right
    return [path, left, right]
  end
  nil
end

begin
  result['compiler'] = run_capture(['xcrun', 'swiftc', '--version'], "#{output}/compiler-version.log").strip
  result['macos_build'] = run_capture(['/usr/bin/sw_vers', '-buildVersion'], "#{output}/macos-version.log").strip
  { 'baseline' => baseline, 'candidate' => candidate }.each do |label, revision|
    sha = run_capture(['git', 'rev-parse', '--verify', '--end-of-options', "#{revision}^{commit}"], "#{output}/#{label}-revision.log").strip
    directory = File.join(output, label)
    FileUtils.mkdir_p(directory)
    archive = File.join(directory, 'sources.tar')
    File.binwrite(archive, run_capture(['git', 'archive', sha, 'native', 'tools/swift-sources.json'], "#{output}/#{label}-archive.log"))
    run_capture(['/usr/bin/tar', '-xf', archive, '-C', directory], "#{output}/#{label}-extract.log")
    File.delete(archive)
    graph = JSON.parse(File.read("#{directory}/tools/swift-sources.json"))
    # Archived checkpoints predate the emulator naming cleanup. Derive their
    # source group from the archived manifest; callers still supply only refs.
    groups = graph.fetch('tests')
    emulator_group = groups.key?('emulator') ? 'emulator' : 'swift_core'
    sources = groups.fetch(emulator_group).reject do |path|
      %w[tests/EmulatorTests.swift tests/SwiftCoreTests.swift].include?(path)
    end
                   .map { |path| "#{directory}/native/#{path}" }
    executable = "#{directory}/probe"
    command = ['xcrun', 'swiftc', '-swift-version', '5', '-O', '-whole-module-optimization', '-target', 'arm64-apple-macosx15.0',
               '-module-name', 'RowStorageProbe', '-import-objc-header', "#{directory}/native/Bridge.h",
               *sources, fixture, '-framework', 'Foundation', '-framework', 'CoreGraphics', '-framework', 'ImageIO', '-o', executable]
    run_capture(command, "#{output}/#{label}-build.log")
    result['revisions'][label] = { 'commit' => sha, 'build_command' => command,
      'inputs' => (sources + ["#{directory}/native/Bridge.h"]).to_h { |path| [path.delete_prefix("#{directory}/"), Digest::SHA256.file(path).hexdigest] },
      'executable_sha256' => Digest::SHA256.file(executable).hexdigest }
  end
  calibration = JSON.parse(run_capture(["#{output}/baseline/probe"], "#{output}/calibration.log"))
  File.write("#{output}/baseline-charges.json", JSON.pretty_generate(calibration.fetch('charges')) + "\n")
  traces = %w[baseline candidate].to_h do |label|
    raw = run_capture(["#{output}/#{label}/probe", "#{output}/baseline-charges.json"], "#{output}/#{label}-probe.log")
    File.write("#{output}/#{label}.json", raw)
    [label, JSON.parse(raw)]
  end
  result['difference'] = first_difference(traces.fetch('baseline'), traces.fetch('candidate'))
  result['records'] = traces.fetch('baseline').fetch('records').length
  result['passed'] = result['difference'].nil?
  puts JSON.pretty_generate(result.slice('passed', 'records', 'difference'))
rescue StandardError => error
  result['failure'] = "#{error.class}: #{error.message}"
  warn result['failure']
ensure
  File.write("#{output}/comparison.json", JSON.pretty_generate(result) + "\n")
end
exit(result['passed'] ? 0 : 1)
