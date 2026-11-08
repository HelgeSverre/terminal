#!/usr/bin/env ruby
# frozen_string_literal: true

# Runs one sequential, immutable-source app-build pair. It is deliberately a
# provenance record for complete app builds, not a statistical or language-only
# compiler comparison: the two checked-in recipes do different work.
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'time'

RUST_SHA = '9cc6f92'.freeze
ROOT = '/Users/helge/code/terminal'.freeze
SWIFT_ROOT = '/Users/helge/code/terminal-swift-experiment'.freeze

abort "usage: #{$PROGRAM_NAME} FINAL_SWIFT_SHA FRESH_OUTPUT_DIRECTORY" unless ARGV.length == 2
swift_revision, output = ARGV
output = File.expand_path(output)
abort "refusing existing output: #{output}" if File.exist?(output)

def sha256(path)
  Digest::SHA256.file(path).hexdigest
end

def command_record(*command)
  output, status = Open3.capture2e(*command)
  {
    'command' => command,
    'exit_status' => status.exitstatus,
    'success' => status.success?,
    'output' => output
  }
end

def exact_revision(repo, revision)
  output, status = Open3.capture2e('git', '-C', repo, 'rev-parse', "#{revision}^{commit}")
  raise "cannot resolve #{revision} in #{repo}: #{output}" unless status.success?

  output.strip
end

def archive(repo, revision, destination)
  tarball, status = Open3.capture2e('git', '-C', repo, 'archive', '--format=tar', revision)
  raise "git archive #{revision} failed: #{tarball}" unless status.success?

  _stdout, stderr, extract_status = Open3.capture3('tar', '-x', '-C', destination, stdin_data: tarball)
  raise "tar extraction failed for #{revision}: #{stderr}" unless extract_status.success?

  Digest::SHA256.hexdigest(tarball)
end

def run(command, chdir:, log:)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  File.open(log, 'wx') do |file|
    pid = Process.spawn(*command, chdir:, out: file, err: file)
    _pid, status = Process.wait2(pid)
    return [status, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
  end
end

def bundle_record(bundle, copy)
  _output, copy_status = Open3.capture2e('ditto', '--rsrc', '--extattr', bundle, copy)
  raise "ditto failed while copying #{bundle}" unless copy_status.success?
  executable = File.join(copy, 'Contents/MacOS/Terminal')
  source_tree_sha256, source_regular_file_bytes = bundle_tree(bundle)
  copy_tree_sha256, copy_regular_file_bytes = bundle_tree(copy)
  code_signing = {
    'source' => command_record('codesign', '--verify', '--deep', '--strict', '--verbose=2', bundle),
    'copy' => command_record('codesign', '--verify', '--deep', '--strict', '--verbose=2', copy)
  }
  record = {
    'copied_bundle' => File.basename(copy),
    'bundle_regular_file_bytes' => copy_regular_file_bytes,
    'source_bundle_tree_sha256' => source_tree_sha256,
    'bundle_tree_sha256' => copy_tree_sha256,
    'code_signing' => code_signing,
    'bundle_verified' => source_tree_sha256 == copy_tree_sha256 &&
      source_regular_file_bytes == copy_regular_file_bytes && code_signing['source']['success'] && code_signing['copy']['success']
  }
  record['executable_sha256'] = sha256(executable) if File.file?(executable)
  record['executable_bytes'] = File.size(executable) if File.file?(executable)
  record
end

def bundle_tree(bundle)
  digest = Digest::SHA256.new
  regular_bytes = 0
  Dir.glob(File.join(bundle, '**/*'), File::FNM_DOTMATCH).select { |path| File.file?(path) }.sort.each do |path|
    relative = path.delete_prefix("#{bundle}/")
    digest << relative << "\0" << sha256(path) << "\n"
    regular_bytes += File.size(path)
  end
  [digest.hexdigest, regular_bytes]
end

FileUtils.mkdir_p(output)
work = File.join(output, 'work')
artifacts = File.join(output, 'artifacts')
FileUtils.mkdir_p([work, artifacts])
manifest_path = File.join(output, 'manifest.json')

result = {
  'schema' => 1,
  'purpose' => 'One sequential complete-app build pair with immutable archived sources.',
  'comparison_limitations' => [
    'This is one paired observation, not a statistical benchmark.',
    'It is not a language-only compiler comparison: the Rust and Swift recipes intentionally perform different project work.',
    'Both runs use fresh project outputs while sharing the host external compiler and dependency caches.'
  ],
  'runner_sha256' => sha256(__FILE__),
  'started_at' => Time.now.utc.iso8601,
  'toolchains' => {
    'swift' => command_record('xcrun', 'swift', '--version'),
    'rustc' => command_record('rustc', '--version'),
    'cargo' => command_record('cargo', '--version')
  },
  'runs' => {}
}

success = false
begin
  plans = [
    ['rust', ROOT, RUST_SHA, ['just', 'build']],
    ['swift', SWIFT_ROOT, swift_revision, ['just', 'release-build']]
  ]

  plans.each do |label, repo, requested_revision, command|
    source = File.join(work, label)
    log = File.join(output, "#{label}-build.log")
    record = { 'requested_revision' => requested_revision, 'log' => File.basename(log) }
    result['runs'][label] = record
    begin
      record['resolved_revision'] = exact_revision(repo, requested_revision)
      FileUtils.mkdir_p(source)
      record['source_archive_sha256'] = archive(repo, record['resolved_revision'], source)
      command = ['env', "CARGO_TARGET_DIR=#{File.join(source, 'target')}", *command] if label == 'rust'
      record['command'] = command
      status, elapsed = run(command, chdir: source, log:)
      record['elapsed_seconds'] = elapsed
      record['exit_status'] = status.exitstatus
      record['success'] = status.success?
      bundle = File.join(source, 'dist', 'Terminal.app')
      if File.directory?(bundle)
        record.merge!(bundle_record(bundle, File.join(artifacts, "#{label}-#{record['resolved_revision']}.app")))
        raise 'copied bundle verification failed' unless record['bundle_verified']
      end
      raise "#{label} build exited #{status.exitstatus}" unless status.success?
    rescue StandardError => error
      record['success'] = false
      record['error'] = "#{error.class}: #{error.message}"
      File.write(manifest_path, JSON.pretty_generate(result) + "\n")
      break
    end
    File.write(manifest_path, JSON.pretty_generate(result) + "\n")
  end
  success = result['runs'].length == plans.length && result['runs'].values.all? { |record| record['success'] }
ensure
  result['finished_at'] = Time.now.utc.iso8601
  result['success'] = success
  File.write(manifest_path, JSON.pretty_generate(result) + "\n") if Dir.exist?(output)
  # Only runner-created source and Cargo-output directories are deleted after
  # logs, manifest, and copied bundles have been recorded.
  FileUtils.rm_rf(work) if Dir.exist?(work)
end

puts "Wrote #{manifest_path}"
exit(success ? 0 : 1)
