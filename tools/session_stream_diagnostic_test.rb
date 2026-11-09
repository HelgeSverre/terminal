# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'tmpdir'

class SessionStreamDiagnosticTest < Minitest::Test
  def test_driver_failure_precedes_nonzero_app_status_and_records_cleanup
    Dir.mktmpdir('terminal-stream-failure-') do |root|
      app = File.join(root, 'Fixture.app')
      FileUtils.mkdir_p(File.join(app, 'Contents/MacOS'))
      executable = File.join(app, 'Contents/MacOS/Terminal')
      File.write(executable, <<~'SCRIPT')
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
          if [ "$1" = --output ]; then shift; printf 'fixture stream driver failed' > "$1.failed"; exit 7; fi
          shift
        done
        exit 8
      SCRIPT
      File.chmod(0o700, executable)
      output = File.join(root, 'diagnostic')
      _, stderr, status = Open3.capture3(RbConfig.ruby,
        File.expand_path('session_stream_diagnostic.rb', __dir__), app, output, '1')
      refute status.success?
      assert_includes stderr, 'fixture stream driver failed'
      report = JSON.parse(File.read(File.join(output, 'diagnostic.json')))
      refute report.fetch('passed')
      assert_includes report.fetch('failure'), 'fixture stream driver failed'
      assert_empty report.fetch('cleanup_survivors')
    end
  end
end
