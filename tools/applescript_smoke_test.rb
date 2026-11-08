# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative 'applescript_smoke'

class AppleScriptSmokeTest < Minitest::Test
  def test_bounded_command_timeout_reaps_its_owned_process
    smoke = AppleScriptSmoke.allocate
    error = assert_raises(AppleScriptSmoke::CommandTimeout) do
      smoke.send(:capture, '/bin/sleep', '30', timeout: 0.1)
    end
    assert error.status.signaled?
    assert_equal 15, error.status.termsig
  end

  def test_failed_lock_never_overwrites_another_fixture_report
    Dir.mktmpdir('terminal-applescript-lock-') do |root|
      target = File.join(root, 'target')
      Dir.mkdir(target)
      lock = File.open(File.join(target, 'automation-fixture.lock'), File::RDWR | File::CREAT, 0o600)
      lock.flock(File::LOCK_EX)
      assert_raises(RuntimeError) { AppleScriptSmoke.new(root).run }
      refute File.exist?(File.join(root, 'reports', 'applescript-smoke.json'))
    ensure
      lock&.flock(File::LOCK_UN)
      lock&.close
    end
  end

  def test_cleanup_failure_is_reported_as_a_failed_run
    Dir.mktmpdir('terminal-applescript-cleanup-') do |root|
      error = assert_raises(RuntimeError) { CleanupFailureSmoke.new(root).run }
      assert_includes error.message, 'Fixture cleanup left processes'
      report = JSON.parse(File.read(File.join(root, 'reports', 'applescript-smoke.json')))
      refute report.fetch('passed')
      assert_match(/Fixture cleanup left processes/, report.fetch('failure'))
    end
  end

  def test_report_failure_still_releases_lock_and_fails_the_run
    Dir.mktmpdir('terminal-applescript-report-') do |root|
      error = assert_raises(Errno::ENOSPC) { ReportFailureSmoke.new(root).run }
      assert_match(/report device full/, error.message)
      lock = File.open(File.join(root, 'target', 'automation-fixture.lock'), File::RDWR | File::CREAT, 0o600)
      assert lock.flock(File::LOCK_EX | File::LOCK_NB)
    ensure
      lock&.flock(File::LOCK_UN)
      lock&.close
    end
  end

  def test_receipt_shell_hashes_every_byte_before_return
    Dir.mktmpdir('terminal-applescript-receipt-') do |root|
      smoke = AppleScriptSmoke.new(root)
      smoke.instance_variable_set(:@fixture_root, root)
      smoke.send(:write_fixture_shell)
      payload = "AUTOMATION_TEXT_#{'x' * 4096}_END"
      input, output, waiter = Open3.popen2e(
        {
          'TERMINAL_AUTOMATION_CHILD_PIDS' => File.join(root, 'children.pids'),
        },
        smoke.instance_variable_get(:@receipt_shell)
      )
      input.write(payload + "\r")
      input.close
      transcript = output.read
      assert waiter.value.success?
      assert_includes transcript, Digest::SHA256.hexdigest(payload)
      receipt = Digest::SHA256.hexdigest(payload)
      wrapped = "AUTOMATION_RECEIPT #{receipt[0, 38]}\n#{receipt[38..]}"
      assert smoke.send(:receipt_in_snapshot?, wrapped, receipt)
    ensure
      output&.close unless output&.closed?
      input&.close unless input&.closed?
    end
  end

  def test_truncated_transcript_stays_valid_utf8_and_records_its_actual_timeout
    smoke = AppleScriptSmoke.allocate
    text = ('x' * (AppleScriptSmoke::OUTPUT_LIMIT - 1)) + "é" + 'trailing'
    truncated = smoke.send(:truncate, text)
    assert truncated.valid_encoding?
    JSON.generate('output' => truncated)
    record = smoke.send(:command_record, 'permission', 'JavaScript', '0', '', nil, false, AppleScriptSmoke::CONSENT_TIMEOUT)
    assert_equal AppleScriptSmoke::CONSENT_TIMEOUT, record.fetch('timeout_seconds')
  end

  class CleanupFailureSmoke < AppleScriptSmoke
    private

    def validate_configuration
      @signing_identity = 'test identity'
    end

    def prepare_fixture
      FileUtils.mkdir_p(@fixture_root)
    end

    def launch_fixture
      @process = Struct.new(:status) do
        def wait(_seconds) = nil
        def live_pids = []
        def cleanup = [4242]
      end.new
    end

    def preflight_permission
      @permission = { 'status' => 0, 'outcome' => 'permitted' }
    end

    def exercise_dictionary; end
    def verify_clean_exit; end
  end

  class ReportFailureSmoke < CleanupFailureSmoke
    private

    def launch_fixture; end

    def write_report
      raise Errno::ENOSPC, 'report device full'
    end
  end
end
