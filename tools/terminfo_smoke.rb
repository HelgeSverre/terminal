#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'tmpdir'

root = File.expand_path('..', __dir__)
source = File.join(root, 'Resources', 'Terminal', 'Terminal.terminfo')
bundle_database = File.join(root, 'dist', 'Terminal.app', 'Contents', 'Resources', 'terminfo')
probe = File.join(root, 'target', 'native', 'terminfo-probe')
raise 'Run just terminfo-test to compile the Swift ABI probe' unless File.executable?(probe)

def run(*command, env: {})
  output, status = Open3.capture2e(env, *command)
  raise "#{command.join(' ')} failed:\n#{output}" unless status.success?

  output
end

def expect_bytes(name, actual, expected)
  return if actual == expected

  raise "#{name}: expected #{expected.inspect}, got #{actual.inspect}"
end

Dir.mktmpdir('helge-terminal-terminfo-') do |temporary|
  database = File.join(temporary, 'terminfo')
  run('/usr/bin/tic', '-x', '-o', database, source)
  listing = run('/usr/bin/infocmp', '-x', '-1', '-A', database, 'helge-terminal')
  %w[am bce km mir msgr colors#256 pairs#32767].each do |capability|
    raise "missing #{capability} in compiled entry" unless listing.include?(capability)
  end
  %w[blink xenl Ms Cr Cs Ss XT].each do |unsupported|
    raise "unsupported inherited capability #{unsupported} present" if listing.match?(/^\s*#{Regexp.escape(unsupported)}(?:=|,|$)/)
  end

  environment = { 'TERMINFO' => database }
  {
    'clear' => "\e[H\e[2J",
    'cup 1 2' => "\e[2;3H",
    'setaf 9' => "\e[91m",
    'setaf 201' => "\e[38;5;201m",
    'setab 9' => "\e[101m",
    'setab 201' => "\e[48;5;201m",
    'acsc' => '``aaffggiijjkkllmmnnooppqqrrssttuuvvwwxxyyzz{{||}}~~',
    'smcup' => "\e[?1049h",
    'rmcup' => "\e[?1049l",
    'smkx' => "\e[?1h\e=",
    'rmkx' => "\e[?1l\e>",
    'khome' => "\eOH",
    'kend' => "\eOF",
    'kent' => "\eOM",
    'sgr0' => "\e(B\e[0m"
  }.each do |capability, expected|
    arguments = capability.split
    expect_bytes(capability, run('/usr/bin/tput', '-T', 'helge-terminal', *arguments, env: environment), expected)
  end

  # Feed strings expanded by tput through the real parser. This covers the
  # screen-clear/cursor/color and alternate-screen capabilities without opening
  # the native app.
  program = +run('/usr/bin/tput', '-T', 'helge-terminal', 'clear', env: environment)
  program << run('/usr/bin/tput', '-T', 'helge-terminal', 'cup', '1', '2', env: environment)
  program << run('/usr/bin/tput', '-T', 'helge-terminal', 'setaf', '201', env: environment)
  program << 'A'
  program << run('/usr/bin/tput', '-T', 'helge-terminal', 'sgr0', env: environment)
  program << run('/usr/bin/tput', '-T', 'helge-terminal', 'smcup', env: environment)
  program << 'X'
  program << run('/usr/bin/tput', '-T', 'helge-terminal', 'rmcup', env: environment)
  snapshot, status = Open3.capture2e(probe, '8', '3', stdin_data: program, chdir: root)
  raise "Swift ABI replay failed:\n#{snapshot}" unless status.success?

  output = JSON.parse(snapshot)
  cell = output.fetch('rows').fetch(1).fetch('cells').fetch(2)
  raise "tput cup/setaf did not reach the parser: #{cell.inspect}" unless cell.fetch('text') == 'A'
  raise "tput setaf lost indexed color: #{cell.inspect}" unless cell.fetch('style').fetch('foreground') == { 'Indexed' => 201 }
  raise 'tput rmcup did not restore the main screen' if output.fetch('alternate')

  acs_program = +run('/usr/bin/tput', '-T', 'helge-terminal', 'smacs', env: environment)
  acs_input = ['`', 'a', 'f', 'g', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z', '{', '|', '}', '~'].join
  acs_program << acs_input
  acs_program << run('/usr/bin/tput', '-T', 'helge-terminal', 'rmacs', env: environment)
  acs_snapshot, status = Open3.capture2e(probe, '40', '2', stdin_data: acs_program, chdir: root)
  raise "Swift ABI ACS replay failed:\n#{acs_snapshot}" unless status.success?

  acs_text = JSON.parse(acs_snapshot).fetch('rows').fetch(0).fetch('cells').map { |item| item.fetch('text') }.join
  raise "tput ACS mapping mismatch: #{acs_text.inspect}" unless acs_text == '◆▒°±␋┘┐┌└┼⎺⎻─⎼⎽├┤┴┬│≤≥π≠£·'
end

bundle_listing = run('/usr/bin/infocmp', '-x', '-1', '-A', bundle_database, 'helge-terminal')
raise 'built bundle is missing helge-terminal terminfo' unless bundle_listing.include?('helge-terminal')
puts 'PASS terminfo: source compiles, bundle contains the entry, tput strings match, and parser accepts them'
