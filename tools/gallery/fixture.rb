#!/usr/bin/env ruby
# frozen_string_literal: true

# Public, disposable shell replacement for README screenshots. Each pane gets
# a different real Files/git/diff view and then remains quiet for capture.
require 'fileutils'

root = File.realpath(ENV.fetch('TERMINAL_GALLERY_DIRECTORY'))
counter = File.join(root, 'pane-counter')
pane = File.open(counter, File::RDWR | File::CREAT, 0o600) do |file|
  file.flock(File::LOCK_EX)
  current = file.read.to_i
  file.rewind; file.truncate(0); file.write((current + 1).to_s)
  current
end
cwd = File.realpath(ENV.fetch('TERMINAL_GALLERY_CWD'))
files = File.realpath(ENV.fetch('TERMINAL_GALLERY_FILES'))
ready = File.join(root, "pane-#{pane}-ready")
scenario = ENV.fetch('TERMINAL_GALLERY_SCENARIO', 'overview')

def section(title)
  STDOUT.write("\e[38;2;92;166;255m#{title}\e[0m\r\n")
end

STDOUT.sync = true
STDOUT.write("\e]0;Terminal\a\e[2J\e[H")
case pane
when 0
  section('workspace  ·  files --color=always')
  system(files, '--color=always', '--no-git', '-L', '2', cwd)
  if scenario == 'panes'
    File.write(ready, "ready\n")
    loop { sleep 60 }
  end
  STDOUT.write("\r\n")
  section('$ git diff --color=always -- src/main.swift')
  Dir.chdir(cwd) { system('/usr/bin/git', 'diff', '--color=always', '--', 'src/main.swift') }
when 1
  section('$ cat src/main.swift')
  File.foreach(File.join(cwd, 'src', 'main.swift')) { |line| STDOUT.write(line) }
when 2
  section('$ git diff --color=always -- src/main.swift')
  Dir.chdir(cwd) { system('/usr/bin/git', 'diff', '--color=always', '--', 'src/main.swift') }
else
  section('terminal')
  system(files, '--color=always', '--no-git', '-L', '2', cwd)
end
File.write(ready, "ready\n")
loop { sleep 60 }
