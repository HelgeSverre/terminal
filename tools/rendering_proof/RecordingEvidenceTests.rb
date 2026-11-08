#!/usr/bin/env ruby
# frozen_string_literal: true

require 'tmpdir'
require_relative 'recording_evidence'

Dir.mktmpdir('rendering-recording-gate-') do |directory|
  summary = File.join(directory, 'summary.json')
  video = File.join(directory, 'capture.mp4')
  reject = lambda do |label|
    begin
      RecordingEvidence.validate!(directory)
    rescue StandardError
      next
    end
    raise "Recording gate accepted #{label}"
  end
  reject.call('missing summary')
  File.write(video, 'synthetic nonempty file; this test checks evidence gates, not video decoding')
  [false, nil, 'true'].each do |finished|
    File.write(summary, JSON.generate(recording_finished: finished))
    reject.call("unfinished recording #{finished.inspect}")
  end
  File.write(summary, JSON.generate(recording_finished: true, recording_error: 'delegate failure'))
  reject.call('delegate failure with finish callback')
  File.write(summary, JSON.generate(recording_finished: true))
  File.delete(video)
  reject.call('missing MP4')
  File.write(video, '')
  reject.call('empty MP4')
  File.write(video, 'synthetic nonempty test payload')
  raise 'Valid finalized recording rejected' unless RecordingEvidence.validate!(directory)[:finalized_nonempty_video]
end
puts 'PASS recording evidence gates: absent/unfinished/error/empty rejected; finalized nonempty accepted'
