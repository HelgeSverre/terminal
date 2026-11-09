# frozen_string_literal: true

require 'base64'
require 'json'
require 'minitest/autorun'
require 'stringio'
require 'tmpdir'

require_relative 'release_signing'

class ReleaseSigningTest < Minitest::Test
  class FakeRunner
    attr_reader :commands

    attr_writer :fail_on

    def initialize(search_list: ['/tmp/login.keychain-db'], fail_on: nil, on_run: nil)
      @search_list = search_list
      @fail_on = fail_on
      @on_run = on_run
      @commands = []
    end

    def output(argv)
      @commands << argv
      fail_if_needed(argv)
      return @search_list.map { |path| %Q{"#{path}"} }.join("\n") + "\n" if argv[1] == 'list-keychains'

      ''
    end

    def run(argv)
      @commands << argv
      @on_run&.call(argv)
      fail_if_needed(argv)
    end

    private

    def fail_if_needed(argv)
      raise ReleaseSigning::Error, 'fake command failure' if @fail_on&.call(argv)
    end
  end

  class FixedRandom
    def initialize
      @index = 0
    end

    def hex(_bytes)
      @index += 1
      format('%064x', @index)
    end
  end

  def test_missing_variables_are_rejected_before_any_command_or_file_is_created
    Dir.mktmpdir('release-signing-test-') do |temp|
      env = valid_env(temp).tap { |values| values.delete('APPLE_TEAM_ID') }
      runner = FakeRunner.new

      error = assert_raises(ReleaseSigning::Error) { signing(env, runner).setup }

      assert_includes error.message, 'APPLE_TEAM_ID'
      assert_empty runner.commands
      refute File.exist?(File.join(temp, ReleaseSigning::STATE_NAME))
    end
  end

  def test_invalid_base64_is_rejected_before_any_command
    Dir.mktmpdir('release-signing-test-') do |temp|
      env = valid_env(temp).merge('APPLE_NOTARY_KEY_BASE64' => 'not base64!')
      runner = FakeRunner.new

      error = assert_raises(ReleaseSigning::Error) { signing(env, runner).setup }

      assert_match(/APPLE_NOTARY_KEY_BASE64/, error.message)
      assert_empty runner.commands
    end
  end

  def test_setup_uses_expected_argv_writes_private_files_and_emits_only_env_assignments
    Dir.mktmpdir('release-signing-test-') do |temp|
      env = valid_env(temp)
      observed_private_files = {}
      runner = FakeRunner.new(on_run: lambda do |argv|
        path = if argv[0, 2] == %w[security import]
                 argv[2]
               elsif argv[0, 3] == %w[xcrun notarytool store-credentials]
                 argv[argv.index('--key') + 1]
               end
        next unless path

        observed_private_files[File.basename(path)] = [File.binread(path), File.stat(path).mode & 0o777]
      end)
      output = StringIO.new

      signing(env, runner, stdout: output).setup

      state_path = File.join(temp, ReleaseSigning::STATE_NAME)
      state = JSON.parse(File.binread(state_path))
      keychain = state.fetch('keychain')
      assert_equal 0o600, File.stat(state_path).mode & 0o777
      assert_equal 0o700, File.stat(state.fetch('work_dir')).mode & 0o777
      assert_equal ['application-certificate-data', 0o600], observed_private_files.fetch('application.p12')
      assert_equal ['installer-certificate-data', 0o600], observed_private_files.fetch('installer.p12')
      assert_equal ['notary-key-data', 0o600], observed_private_files.fetch('notary-key.p8')
      assert_equal [
        "APPLE_NOTARY_PROFILE=terminal-notary-#{format('%064x', 2)}",
        "APPLE_SIGNING_KEYCHAIN=#{keychain}"
      ], output.string.lines(chomp: true)
      refute_match(/password|certificate-data|notary-key-data/, output.string)

      assert_includes runner.commands, ['security', 'create-keychain', '-p', format('%064x', 3), keychain]
      assert_includes runner.commands, ['security', 'list-keychains', '-d', 'user', '-s', keychain, '/tmp/login.keychain-db']
      imports = runner.commands.select { |argv| argv[0, 2] == %w[security import] }
      assert_equal 2, imports.length
      imports.each do |argv|
        allowed_tools = argv.each_index.each_with_object([]) do |index, tools|
          tools << argv[index + 1] if argv[index] == '-T'
        end
        assert_equal ['/usr/bin/codesign', '/usr/bin/pkgbuild', '/usr/bin/productsign'], allowed_tools
      end
      assert_includes runner.commands, ['security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s', '-k', format('%064x', 3), keychain]
      notary = runner.commands.find { |argv| argv[0, 3] == %w[xcrun notarytool store-credentials] }
      refute_nil notary
      assert_equal keychain, notary[notary.index('--keychain') + 1]
      refute File.exist?(File.join(state.fetch('work_dir'), 'notary-key.p8'))
      refute File.exist?(File.join(state.fetch('work_dir'), 'application.p12'))
      refute File.exist?(File.join(state.fetch('work_dir'), 'installer.p12'))
    end
  end

  def test_setup_failure_restores_search_list_and_removes_state
    Dir.mktmpdir('release-signing-test-') do |temp|
      env = valid_env(temp)
      runner = FakeRunner.new(fail_on: ->(argv) { argv[0, 2] == %w[security import] })

      assert_raises(ReleaseSigning::Error) { signing(env, runner).setup }

      refute File.exist?(File.join(temp, ReleaseSigning::STATE_NAME))
      refute Dir.children(temp).any? { |name| name.start_with?('terminal-signing-') }
      assert runner.commands.any? { |argv| argv[0, 2] == %w[security delete-keychain] }
      restores = runner.commands.select { |argv| argv[0, 5] == ['security', 'list-keychains', '-d', 'user', '-s'] }
      assert_equal ['security', 'list-keychains', '-d', 'user', '-s', '/tmp/login.keychain-db'], restores.last
    end
  end

  def test_cleanup_retains_state_for_a_retry_when_it_cannot_restore_the_search_list
    Dir.mktmpdir('release-signing-test-') do |temp|
      env = valid_env(temp)
      runner = FakeRunner.new
      subject = signing(env, runner)
      subject.setup
      state_path = File.join(temp, ReleaseSigning::STATE_NAME)
      runner.fail_on = lambda do |argv|
        argv[0, 5] == ['security', 'list-keychains', '-d', 'user', '-s'] &&
          argv.last == '/tmp/login.keychain-db'
      end

      assert_raises(ReleaseSigning::Error) { subject.cleanup }
      assert File.exist?(state_path)

      runner.fail_on = nil
      subject.cleanup
      refute File.exist?(state_path)
    end
  end

  def test_cleanup_is_idempotent_and_restores_the_original_search_list
    Dir.mktmpdir('release-signing-test-') do |temp|
      env = valid_env(temp)
      runner = FakeRunner.new
      subject = signing(env, runner)
      subject.setup
      state_path = File.join(temp, ReleaseSigning::STATE_NAME)
      state = JSON.parse(File.binread(state_path))
      File.write(state.fetch('keychain'), '')

      subject.cleanup
      subject.cleanup

      refute File.exist?(state_path)
      refute Dir.exist?(state.fetch('work_dir'))
      assert_includes runner.commands, ['security', 'delete-keychain', state.fetch('keychain')]
      restores = runner.commands.select { |argv| argv[0, 5] == ['security', 'list-keychains', '-d', 'user', '-s'] }
      assert_equal ['security', 'list-keychains', '-d', 'user', '-s', '/tmp/login.keychain-db'], restores.last
    end
  end

  private

  def signing(env, runner, stdout: StringIO.new)
    ReleaseSigning.new(env: env, runner: runner, stdout: stdout, random: FixedRandom.new)
  end

  def valid_env(temp)
    {
      'RUNNER_TEMP' => temp,
      'APPLE_APPLICATION_CERTIFICATE_BASE64' => Base64.strict_encode64('application-certificate-data'),
      'APPLE_APPLICATION_CERTIFICATE_PASSWORD' => 'application-password',
      'APPLE_INSTALLER_CERTIFICATE_BASE64' => Base64.strict_encode64('installer-certificate-data'),
      'APPLE_INSTALLER_CERTIFICATE_PASSWORD' => 'installer-password',
      'APPLE_NOTARY_KEY_BASE64' => Base64.strict_encode64('notary-key-data'),
      'APPLE_NOTARY_KEY_ID' => 'ABCDEFGHIJ',
      'APPLE_NOTARY_ISSUER_ID' => 'issuer-id',
      'APPLE_APPLICATION_SIGNING_IDENTITY' => 'Developer ID Application: Example',
      'APPLE_INSTALLER_SIGNING_IDENTITY' => 'Developer ID Installer: Example',
      'APPLE_TEAM_ID' => 'TEAMID1234'
    }
  end
end
