# frozen_string_literal: true

require 'digest'
require_relative 'native_smoke'

HELP = <<~TEXT
  Usage: ruby tools/compare_csi_dispatch.rb BASE_REF CANDIDATE_REF NEW_OUTPUTDIR
  Freeze canonical-layout source inputs from two Git commits, compile the same
  local CSI corpus with WMO, and compare 62,918 snapshot/reply digest records.
  Requires macOS/Xcode. Retains sources, binaries, logs, and traces in a new
  private output directory; never adds them to Git. Older native/ layouts fail.
TEXT
if ARGV == ['--help'] || ARGV == ['-h']
  puts HELP
  exit
end
if ARGV == ['--version']
  puts 'compare_csi_dispatch 1'
  exit
end
abort HELP unless ARGV.length == 3 && ARGV.none? { |arg| arg.start_with?('-') }
Signal.trap('TERM') { raise Interrupt, 'CSI comparison terminated' }
Signal.trap('INT') { raise Interrupt, 'CSI comparison interrupted' }

ROOT = File.expand_path('..', __dir__)
GRAPH = 'tools/swift-sources.json'
HEADER = 'Sources/Terminal/Interop/Bridge.h'
CORPUS = 'Tests/TerminalTests/CSIDifferentialProbe.swift'
FLAGS = %w[-swift-version 5 -O -whole-module-optimization].freeze
EXPECTED_LINES = 62_918

def git(*arguments)
  output, status = Open3.capture2e('git', '-C', ROOT, *arguments)
  raise "git #{arguments.first} failed: #{output.strip}" unless status.success?
  output
end

def sha(path)
  Digest::SHA256.file(path).hexdigest
end

def run(command, log, seconds)
  process = NativeSmokeProcess.new(command, log: log)
  begin
    status = process.wait(seconds)
    raise "Timed out after #{seconds}s; inspect #{log}" unless status
    raise "Process failed (#{status}); inspect #{log}" unless status.success?
    raise "Process left children: #{process.live_pids.inspect}" unless process.live_pids.empty?
  ensure
    remaining = process.cleanup
    raise "Processes survived cleanup: #{remaining.inspect}" unless remaining.empty?
  end
end

report = { 'passed' => false, 'flags' => FLAGS, 'runs' => {} }
output = nil
begin
  refs = ARGV.take(2).map { |ref| git('rev-parse', '--verify', '--end-of-options', "#{ref}^{commit}").strip }
  frozen_graphs = refs.to_h do |commit|
    graph_text = git('show', "#{commit}:#{GRAPH}")
    sources = JSON.parse(graph_text).fetch('emulation')
    unless sources.is_a?(Array) && !sources.empty? && sources.uniq == sources && sources.all? { |path|
      path.is_a?(String) && path.start_with?('Sources/Terminal/') && path.end_with?('.swift') &&
      path.split('/').none? { |part| part.empty? || part == '.' || part == '..' }
    }
      raise "#{commit}: requires canonical Sources/Terminal emulation graph; old layouts unsupported"
    end
    git('cat-file', '-e', "#{commit}:#{HEADER}")
    [commit, [graph_text, sources]]
  end
  corpus_source = File.join(ROOT, CORPUS)
  raise "Missing shared corpus: #{corpus_source}" unless File.file?(corpus_source)
  destination = File.expand_path(ARGV[2])
  raise "Output already exists: #{destination}" if File.exist?(destination) || File.symlink?(destination)
  # mkdir is exclusive; do not reuse or clean an existing directory.
  Dir.mkdir(destination, 0o700)
  File.chmod(0o700, destination)
  output = destination
  corpus = File.join(output, 'CSIDifferentialProbe.swift')
  FileUtils.cp(corpus_source, corpus)
  report['corpus_sha256'] = sha(corpus)
  report['runner_sha256'] = sha(__FILE__)
  report['process_helper_sha256'] = sha(File.join(__dir__, 'native_smoke.rb'))
  run(%w[xcrun swiftc --version], File.join(output, 'compiler.txt'), 30)
  report['compiler'] = File.read(File.join(output, 'compiler.txt'))
  %w[baseline candidate].zip(refs).each do |name, commit|
    directory = File.join(output, name)
    FileUtils.mkdir_p(directory)
    graph_text, sources = frozen_graphs.fetch(commit)
    inputs = [GRAPH, HEADER, *sources]
    hashes = inputs.to_h do |path|
      target = File.join(directory, path)
      FileUtils.mkdir_p(File.dirname(target))
      File.binwrite(target, path == GRAPH ? graph_text : git('show', "#{commit}:#{path}"))
      [path, sha(target)]
    end
    executable = File.join(directory, 'csi-probe')
    command = ['xcrun', 'swiftc', *FLAGS, '-module-cache-path', File.join(directory, 'module-cache'),
      '-import-objc-header', File.join(directory, HEADER), *sources.map { |path| File.join(directory, path) },
      corpus, '-framework', 'Foundation', '-framework', 'CoreGraphics', '-framework', 'ImageIO', '-o', executable]
    entry = report['runs'][name] = { 'commit' => commit, 'source_sha256' => hashes, 'command' => command }
    warn "Compiling #{name} #{commit}"
    run(command, File.join(directory, 'compile.log'), 300)
    entry['executable_sha256'] = sha(executable)
    trace = File.join(directory, 'trace.txt')
    warn "Running #{name} CSI corpus"
    run([executable], trace, 600)
    lines = 0
    File.foreach(trace) do |line|
      raise "Unexpected trace record in #{trace}" unless /\A\d+:-?\d+:SHA256 digest: [0-9a-f]{64}\n\z/.match?(line)
      lines += 1
    end
    entry['line_count'] = lines
    entry['output_sha256'] = sha(trace)
    raise "Expected #{EXPECTED_LINES} records, got #{lines}: #{trace}" unless lines == EXPECTED_LINES
  end
  traces = %w[baseline candidate].map { |name| File.join(output, name, 'trace.txt') }
  hashes = report['runs'].values.map { |entry| entry.fetch('output_sha256') }
  raise 'CSI output differs; inspect retained traces' unless hashes.uniq.length == 1 && FileUtils.compare_file(*traces)
  report['passed'] = true
  warn "PASS CSI differential: #{EXPECTED_LINES} records; #{File.join(output, 'comparison.json')}"
rescue StandardError, Interrupt => error
  report['failure'] = "#{error.class}: #{error.message}"
  warn report['failure']
ensure
  File.write(File.join(output, 'comparison.json'), JSON.pretty_generate(report) + "\n") if output
end
exit(report['passed'] ? 0 : 1)
