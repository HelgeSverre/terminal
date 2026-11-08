require 'json'; require 'digest'; require 'open3'
r = File.expand_path('reports/swift-integration-direct-snapshot-4a26322')
results = JSON.parse(File.read("#{r}/results.json"))
graph = JSON.parse(File.read('tools/swift-sources.json'))
old = JSON.parse(File.read("#{r}/inputs.json"))
changed = old.filter { |path, sha| Digest::SHA256.file(path).hexdigest != sha }.keys
expected = %w[native/tests/SnapshotBridgeTests.swift native/tests/BinarySnapshotOracle.swift]
abort "Unexpected source changes: #{changed}" unless (changed - expected).empty?
File.write("#{r}/fixture-correction.json", JSON.pretty_generate({changed: changed, reason: 'Active OSC8 empty URI correctly maps to nil; imported isolated assertion expected empty String. All three snapshot projections already agreed. Keep failure and add separate binary empty-sentinel control.', final_hashes: changed.to_h { |p| [p, Digest::SHA256.file(p).hexdigest] }})+"\n")
commands = [
 ['snapshot_bridge-revised-compile', %w[xcrun swiftc -D SNAPSHOT_ABI_DIAGNOSTICS -swift-version 5 -O -import-objc-header native/Bridge.h]+graph['tests']['snapshot_bridge'].map{|s|"native/#{s}"}+%w[target/native/integration-Spawn.o -framework Foundation -framework CoreFoundation -framework CoreGraphics -framework ImageIO -framework Security -liconv -o target/native/integration-snapshot_bridge]],
 ['snapshot_bridge-revised', ['target/native/integration-snapshot_bridge']],
 ['session', ['target/native/integration-session', "#{r}/session-fixture"]]
]
commands.each do |name, args|
  puts "START #{name}"; $stdout.flush
  out,err,status = Open3.capture3(*args)
  File.write("#{r}/#{name}.stdout.log", out); File.write("#{r}/#{name}.stderr.log",err)
  results << {name:name,command:args,exit:status.exitstatus,signal:status.termsig,passed:status.success?}
  File.write("#{r}/results.json", JSON.pretty_generate(results)+"\n")
  puts "#{status.success? ? 'PASS' : 'FAIL'} #{name}"; $stdout.flush
  exit 1 unless status.success?
end
File.write("#{r}/source-stability.json", JSON.pretty_generate({passed:true, production_changed:false, test_fixture_correction:changed})+"\n")
