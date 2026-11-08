# frozen_string_literal: true

require 'json'

module RecordingEvidence
  def self.validate!(directory)
    summary = JSON.parse(File.read(File.join(directory, 'summary.json')))
    raise 'Recording completion delegate did not report success' unless summary['recording_finished'] == true
    raise 'Recording reported an error' if summary['recording_error'] || summary['recording_validation_error']
    video = File.join(directory, 'capture.mp4')
    raise 'Finalized recording has no nonempty MP4' unless File.file?(video) && File.size(video).positive?

    { summary: summary, video_bytes: File.size(video), finalized_nonempty_video: true }
  end
end
