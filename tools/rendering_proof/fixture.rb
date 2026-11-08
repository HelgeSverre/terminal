#!/usr/bin/ruby
# frozen_string_literal: true

require 'io/console'
require 'json'

def image(pane, generation, rows, columns, negative: false)
  color = [[255, 0, 255], [0, 255, 0], [0, 255, 255]].fetch(pane)
  text = +"\e[?25l\e[0m\e[2J\e[H\e]2;Synthetic rendering proof\a"
  text << "PANE_#{pane} GEN_#{generation} #{columns}x#{rows}\r\n"
  text << "ASCII Aa09 | Ω中 café | 🐈 👩‍💻\r\n"
  2.times do |row|
    text << "\e[#{4 + row};3H\e[48;2;#{color.join(';')}m#{' ' * (negative ? 12 : 6)}\e[0m"
  end
  checksum = (generation ^ (generation >> 8) ^ pane ^ 0xa5) & 0xff
  code = 0xa | ((generation & 0xffff) << 4) | (checksum << 20) | (0x5 << 28)
  32.times do |bit|
    value = (code & (1 << bit)).zero? ? 0 : 255
    text << "\e[#{7 + bit / 8};#{3 + bit % 8}H\e[48;2;#{value};#{value};#{value}m \e[0m"
  end
  text << "\e[12;1HPANE_#{pane} FINAL=#{(generation & 0x8000) != 0}\e[0m"
end

if ARGV == ['--self-test']
  generation = 0x8000 | (20 << 8) | 80
  (0..2).each do |pane|
    output = image(pane, generation, 20, 80)
    raise unless output.include?("PANE_#{pane} FINAL=true")
    cells = output.scan(/\e\[(\d+);(\d+)H\e\[48;2;(\d+);(\d+);(\d+)m /).map { |items| items.map(&:to_i) }
      .select { |row, column, red, green, blue| (7..10).cover?(row) && (3..10).cover?(column) && red == green && green == blue }
    raise 'Wrong barcode cell count' unless cells.length == 32
    code = cells.sum { |row, column, red, _green, _blue| red == 255 ? 1 << ((row - 7) * 8 + column - 3) : 0 }
    raise 'Wrong barcode payload' unless ((code >> 4) & 0xffff) == generation && (code & 0xf) == 0xa && (code >> 28) == 0x5
    raise 'Wrong pane checksum' unless ((code >> 20) & 0xff) == ((generation ^ (generation >> 8) ^ pane ^ 0xa5) & 0xff)
  end
  raise unless image(1, 1, 20, 80, negative: true).include?(' ' * 12)
  puts 'PASS synthetic fixture: pane IDs, sentinel/checksum barcode, explicit doubled-width negative control'
  exit
end

directory = ENV.fetch('TERMINAL_RENDER_PROOF_DIRECTORY')
id = File.open(File.join(directory, 'pane-counter'), File::RDWR | File::CREAT, 0o600) do |file|
  file.flock(File::LOCK_EX)
  value = file.read.to_i
  file.rewind
  file.truncate(0)
  file.write((value + 1).to_s)
  value
end
abort 'Unexpected additional fixture pane' unless (0..2).cover?(id)
STDOUT.sync = true
system('/bin/stty', 'raw', '-echo') or abort 'Cannot configure fixture PTY'
generation = 0
dirty = true
final = false
Signal.trap('WINCH') { dirty = true }
Signal.trap('TERM') { exit }
Signal.trap('HUP') { exit }
File.write(File.join(directory, "pane-#{id}.json"), JSON.generate(pane: id, pid: Process.pid))
deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60
while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
  if !final && File.exist?(File.join(directory, 'final-output'))
    final = true
    dirty = true
  end
  if dirty
    dirty = false
    rows, columns = STDOUT.winsize
    abort 'Fixture geometry exceeds barcode encoding' unless (1..127).cover?(rows) && (1..255).cover?(columns)
    generation = final ? 0x8000 | (rows << 8) | columns : generation + 1
    STDOUT.write(image(id, generation, rows, columns, negative: ENV['TERMINAL_RENDER_PROOF_NEGATIVE'] == '1'))
    File.open(File.join(directory, "pane-#{id}-events.jsonl"), 'a') do |file|
      file.puts JSON.generate(pane: id, generation: generation, final: final, rows: rows, columns: columns,
        host_time: Process.clock_gettime(Process::CLOCK_UPTIME_RAW), pid: Process.pid)
    end
  end
  sleep 0.02
end
