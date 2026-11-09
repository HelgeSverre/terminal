#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'optparse'
require 'rbconfig'
require 'tmpdir'
require_relative '../native_smoke'

ROOT = File.expand_path('../..', __dir__)
FIXTURE = File.join(__dir__, 'fixture.rb')
DRIVER = File.join(__dir__, 'Driver.swift')
CAPTURE = File.join(__dir__, 'Capture.swift')

def compile(source, output)
  raise "compile failed: #{source}" unless system('xcrun', 'swiftc', '-parse-as-library', '-O', source, '-o', output)
end

def resolve_executable(name, explicit, fallback)
  if explicit
    path = File.expand_path(explicit)
    raise "not an executable: #{path}" unless File.file?(path) && File.executable?(path)
    return path
  end
  candidates = []
  candidates.concat(ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).map { |directory| File.join(directory, name) })
  candidates << fallback
  executable = candidates.map { |candidate| File.expand_path(candidate) }.find { |candidate| File.file?(candidate) && File.executable?(candidate) }
  raise "could not find executable for #{name}; pass --#{name} PATH" unless executable

  executable
end

options = { app: File.join(ROOT, 'dist/Terminal.app'), files: nil }
OptionParser.new do |parser|
  parser.on('--app PATH') { |value| options[:app] = File.expand_path(value) }
  parser.on('--files PATH') { |value| options[:files] = File.expand_path(value) }
  parser.on('--source-sha SHA') { |value| options[:source_sha] = value }
end.parse!
scenario = ARGV.fetch(0, 'overview')
raise 'Usage: ruby tools/gallery/run.rb overview|panes' unless %w[overview panes].include?(scenario)
destination = File.join(ROOT, 'assets/screenshots', "#{scenario}.png")
FileUtils.mkdir_p(File.dirname(destination))
raise 'gallery app is missing' unless File.directory?(options[:app])
source_executable = File.join(options[:app], 'Contents/MacOS/Terminal')
raise 'gallery executable is missing' unless File.executable?(source_executable)
source_sha256 = Digest::SHA256.file(source_executable).hexdigest
files = resolve_executable('files', options[:files], File.join(Dir.home, '.local/bin/files'))
Signal.trap('INT') { raise Interrupt, 'Gallery capture interrupted' }
Signal.trap('TERM') { raise Interrupt, 'Gallery capture terminated' }

Dir.mktmpdir("terminal-gallery-#{scenario}-") do |directory|
  fixture_cwd = File.join(directory, 'workspace')
  FileUtils.mkdir_p(File.join(fixture_cwd, 'src'))
  FileUtils.mkdir_p(File.join(fixture_cwd, 'assets'))
  File.write(File.join(fixture_cwd, 'README.md'), "# Terminal\n\nA native terminal for focused work.\n")
  source = File.join(fixture_cwd, 'src', 'main.swift')
  File.write(source, "import Foundation\nprint(\"Hello, Terminal\")\n")
  File.write(File.join(fixture_cwd, 'assets', 'logo.svg'), "<svg xmlns=\"http://www.w3.org/2000/svg\"/>\n")
  raise 'public fixture Git initialization failed' unless system('/usr/bin/git', '-C', fixture_cwd, 'init', '-q') && system('/usr/bin/git', '-C', fixture_cwd, 'add', 'src/main.swift')
  File.write(source, "import Foundation\n\nprint(\"Hello, Terminal\")\nprint(\"Ready for focused work\")\n")
  FileUtils.cp_r(options[:app], File.join(directory, 'Gallery Terminal.app'))
  executable = File.join(directory, 'Gallery Terminal.app', 'Contents/MacOS/Terminal')
  driver = File.join(directory, 'GalleryDriver')
  capture = File.join(directory, 'GalleryCapture')
  compile(DRIVER, driver); compile(CAPTURE, capture)
  environment = {
    'PATH' => [File.dirname(files), '/usr/bin', '/bin', '/usr/sbin', '/sbin'].join(File::PATH_SEPARATOR), 'SHELL' => FIXTURE,
    'TERM' => 'xterm-256color', 'COLORTERM' => 'truecolor', 'NO_COLOR' => nil,
    'TERMINAL_GALLERY_DIRECTORY' => directory, 'TERMINAL_GALLERY_CWD' => fixture_cwd,
    'TERMINAL_GALLERY_FILES' => files, 'TERMINAL_GALLERY_EXECUTABLE' => executable,
    'TERMINAL_GALLERY_SCENARIO' => scenario
  }
  processes = []
  report = { scenario: scenario, source_app: options[:app], source_revision: options[:source_sha], executable_sha256: source_sha256,
    fixture: 'public disposable Files/git/diff content' }
  staged_destination = File.join(File.dirname(destination), ".#{scenario}-#{Process.pid}.pending.png")
  begin
    app = NativeSmokeProcess.new([environment, executable, '--font-size', '18', '--columns', '112', '--rows', '38', '--execute', RbConfig.ruby, FIXTURE], log: File.join(directory, 'app.log'))
    processes << app
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
    until File.file?(File.join(directory, 'pane-0-ready'))
      raise 'gallery app exited before fixture became ready' if app.wait(0.05)
      raise 'gallery fixture startup timed out' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    end
    driver_process = NativeSmokeProcess.new([environment, driver, scenario, app.pid.to_s, directory], log: File.join(directory, 'driver.log'))
    processes << driver_process
    raise 'gallery window setup failed' unless driver_process.wait(15)&.success?
    identity = JSON.parse(File.read(File.join(directory, 'identity.json')))
    capture_process = NativeSmokeProcess.new([capture, identity.fetch('window').to_s, app.pid.to_s, File.join(directory, 'capture.png')], log: File.join(directory, 'capture.log'))
    processes << capture_process
    raise 'gallery PNG capture failed' unless capture_process.wait(12)&.success?
    raise 'gallery capture is missing' unless File.size?(File.join(directory, 'capture.png'))
    FileUtils.cp(File.join(directory, 'capture.png'), staged_destination)
    report[:identity] = identity
    report[:output] = destination
    report[:png_sha256] = Digest::SHA256.file(staged_destination).hexdigest
    report[:passed] = true
  rescue Exception => error
    report[:passed] = false; report[:error] = "#{error.class}: #{error.message}"
    raise
  ensure
    report[:cleanup] = processes.reverse.map { |process| { pid: process.pid, survivors: process.cleanup } }
    cleanup_passed = report[:cleanup].all? { |entry| entry[:survivors].empty? }
    report[:passed] &&= cleanup_passed
    begin
      File.write(File.join(File.dirname(destination), ".#{scenario}.capture.json"), JSON.pretty_generate(report) + "\n")
      File.rename(staged_destination, destination) if report[:passed] && File.file?(staged_destination)
    ensure
      FileUtils.rm_f(staged_destination)
    end
    raise 'gallery process cleanup failed' unless cleanup_passed
  end
end

puts "PASS gallery #{scenario}: #{destination}"
