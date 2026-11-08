require 'json'
require 'digest'
require 'fileutils'
require 'open3'
root = Dir.pwd
report = File.join(root, 'reports/swift-integration-direct-snapshot-4a26322')
graph = JSON.parse(File.read('tools/swift-sources.json'))
inputs = graph['app'].map { |source| "native/#{source}" } + graph['tests'].values.flatten.map { |source| "native/#{source}" } + %w[tools/swift-sources.json native/Bridge.h native/Spawn.c native/Launcher.c justfile]
hashes = inputs.uniq.to_h { |path| [path, Digest::SHA256.file(path).hexdigest] }
File.write("#{report}/inputs.json", JSON.pretty_generate(hashes) + "\n")
results = []
def gate(results, report, name, command)
  puts "START #{name}"
  $stdout.flush
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  out, err, status = Open3.capture3(*command)
  File.write("#{report}/#{name}.stdout.log", out)
  File.write("#{report}/#{name}.stderr.log", err)
  results << { name: name, command: command, exit: status.exitstatus, signal: status.termsig, passed: status.success?, seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - start }
  File.write("#{report}/results.json", JSON.pretty_generate(results) + "\n")
  puts "#{status.success? ? 'PASS' : 'FAIL'} #{name}"
  $stdout.flush
  exit(1) unless status.success?
end
%w[terminal-document-ownership swift-core-test terminal-viewport-oracle terminal-graphics-oracle terminal-palette terminal-scheduler-oracle terminal-prompt-clear-oracle].each do |name|
  gate(results, report, name, ['just', name])
end
frameworks = %w[Foundation CoreFoundation CoreGraphics ImageIO Security].flat_map { |name| ['-framework', name] } + ['-liconv']
base = %w[xcrun swiftc -swift-version 5 -O -import-objc-header native/Bridge.h]
gate(results, report, 'spawn', %w[xcrun clang -Wall -Wextra -Werror -mmacosx-version-min=15.0 -c native/Spawn.c -o target/native/integration-Spawn.o])
%w[snapshot_bridge session].each do |group|
  command = base + (group == 'snapshot_bridge' ? ['-D', 'SNAPSHOT_ABI_DIAGNOSTICS'] : []) + graph['tests'][group].map { |s| "native/#{s}" } + ['target/native/integration-Spawn.o'] + frameworks + ['-o', "target/native/integration-#{group}"]
  gate(results, report, "#{group}-compile", command)
end
fixture = File.join(report, 'session-fixture')
FileUtils.mkdir_p("#{fixture}/dist/Terminal.app/Contents/MacOS")
FileUtils.mkdir_p("#{fixture}/reports")
gate(results, report, 'launcher', ['xcrun', 'clang', '-Wall', '-Wextra', '-Werror', '-mmacosx-version-min=15.0', 'native/Launcher.c', '-o', "#{fixture}/dist/Terminal.app/Contents/MacOS/TerminalLauncher"])
gate(results, report, 'snapshot_bridge', ['target/native/integration-snapshot_bridge'])
gate(results, report, 'session', ['target/native/integration-session', fixture])
changed = hashes.filter { |path, hash| Digest::SHA256.file(path).hexdigest != hash }.keys
File.write("#{report}/source-stability.json", JSON.pretty_generate({ passed: changed.empty?, changed: changed }) + "\n")
abort "Sources changed: #{changed}" unless changed.empty?
