# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

# Exercise the actual just recipe, including its shell lifetime. Nested compile
# and test commands are replaced; this policy test never touches Metal or a GUI.
root = File.expand_path('..', __dir__)
lines = File.readlines(File.join(root, 'justfile'))
start = lines.index { |line| line.start_with?('_glyph-rendering-tests:') }
raise 'missing glyph gate' unless start
finish = start + 1
finish += 1 while finish < lines.length && (lines[finish].start_with?('    ') || lines[finish].strip.empty?)
recipe = lines[start...finish].join
just = ENV.fetch('PATH').split(File::PATH_SEPARATOR).map { |path| File.join(path, 'just') }.find { |path| File.executable?(path) }
raise 'just is required' unless just

Dir.mktmpdir('terminal-glyph-policy-') do |temporary|
  FileUtils.mkdir_p(File.join(temporary, 'bin'))
  File.write(File.join(temporary, 'justfile'), recipe)
  File.write(File.join(temporary, 'bin', 'just'), <<~'SH')
    #!/bin/bash
    printf '%s\n' "$1" >> invoked
    if [[ "$1" == _glyph-raster-tests ]]; then exit "${CPU_STATUS:-0}"; fi
  SH
  File.write(File.join(temporary, 'bin', 'xcrun'), <<~'SH')
    #!/bin/bash
    if [[ "$1" == swift ]]; then
      echo tests/MetalUploadProbe.swift
    else
      cp "$PROBE_SOURCE" target/native/metal-upload-probe
      chmod +x target/native/metal-upload-probe
    fi
  SH
  File.chmod(0o755, File.join(temporary, 'bin', 'just'), File.join(temporary, 'bin', 'xcrun'))
  cases = [
    ['known-driver-fault', 139, true, false, 'paravirtual', 0, 0, false, true],
    ['unknown-fault', 139, false, false, 'paravirtual', 0, 139, false, false],
    ['different-error', 1, true, false, 'paravirtual', 0, 1, false, false],
    ['probe-success', 0, true, true, 'paravirtual', 0, 0, true, false],
    ['later-driver-fault', 139, true, true, 'paravirtual', 0, 139, false, false],
    ['local-default', 139, true, false, '', 0, 0, true, false],
    ['cpu-failure', 139, true, false, 'paravirtual', 7, 7, false, false]
  ]
  cases.each do |name, probe_status, known, completed, policy, cpu_status, expected_status, gpu, skipped|
    markers = known ? <<~'SH' : "echo unknown\n"
      echo 'METAL_UPLOAD_DEVICE=name=Apple Paravirtual registry=1'
      echo 'METAL_UPLOAD_PROBE=after_shared_texture_replace'
      echo 'METAL_UPLOAD_PROBE=before_shared_heap_texture_replace'
    SH
    markers += "echo 'METAL_UPLOAD_PROBE=after_shared_heap_texture_replace'\n" if completed
    File.write(File.join(temporary, 'probe'), "#!/bin/bash\n#{markers}exit #{probe_status}\n")
    FileUtils.rm_f(File.join(temporary, 'invoked'))
    # A prior skip must never survive a local pass or a failed current run.
    FileUtils.mkdir_p(File.join(temporary, 'reports', 'gpu-policy'))
    result_path = File.join(temporary, 'reports', 'gpu-policy', 'glyph-residency.json')
    File.write(result_path, '{"status":"stale"}')
    environment = {
      'PATH' => "#{temporary}/bin:#{ENV.fetch('PATH')}",
      'PROBE_SOURCE' => File.join(temporary, 'probe'),
      'TERMINAL_CI_GPU_POLICY' => policy, 'CPU_STATUS' => cpu_status.to_s
    }
    output, status = Open3.capture2e(environment, just, '--justfile', File.join(temporary, 'justfile'), '_glyph-rendering-tests', chdir: temporary)
    calls = File.readlines(File.join(temporary, 'invoked'), chomp: true)
    raise "#{name}: #{status.exitstatus}\n#{output}" unless status.exitstatus == expected_status
    raise "#{name}: missing CPU gate" unless calls.first == '_glyph-raster-tests'
    raise "#{name}: wrong GPU gate" unless calls.include?('_glyph-residency-tests') == gpu
    raise "#{name}: wrong skip report" unless File.exist?(result_path) == skipped
    raise "#{name}: invalid skip report" if skipped && JSON.parse(File.read(result_path)).fetch('status') != 'skipped'
    puts "PASS glyph policy #{name}"
  end
end
