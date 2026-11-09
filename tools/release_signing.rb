#!/usr/bin/env ruby
# frozen_string_literal: true

# Prepares an isolated keychain for a CI release.  This deliberately keeps all
# secrets in memory or in a private RUNNER_TEMP directory; the state file only
# contains enough information for cleanup to restore the keychain search list.

require 'base64'
require 'fileutils'
require 'json'
require 'open3'
require 'securerandom'
require 'shellwords'

class ReleaseSigning
  STATE_NAME = 'terminal-signing-state.json'
  REQUIRED_ENV = %w[
    APPLE_APPLICATION_CERTIFICATE_BASE64
    APPLE_APPLICATION_CERTIFICATE_PASSWORD
    APPLE_INSTALLER_CERTIFICATE_BASE64
    APPLE_INSTALLER_CERTIFICATE_PASSWORD
    APPLE_NOTARY_KEY_BASE64
    APPLE_NOTARY_KEY_ID
    APPLE_NOTARY_ISSUER_ID
    APPLE_APPLICATION_SIGNING_IDENTITY
    APPLE_INSTALLER_SIGNING_IDENTITY
    APPLE_TEAM_ID
  ].freeze

  class Error < StandardError; end

  class CommandRunner
    def run(argv)
      _stdout, _stderr, status = Open3.capture3(*argv)
      return if status.success?

      # Arguments can contain passwords. Do not include them, or command output,
      # in an exception that GitHub Actions could print.
      raise Error, "#{argv.first} #{argv[1]} failed"
    end

    def output(argv)
      stdout, _stderr, status = Open3.capture3(*argv)
      return stdout if status.success?

      raise Error, "#{argv.first} #{argv[1]} failed"
    end
  end

  def initialize(env: ENV, runner: CommandRunner.new, stdout: $stdout, stderr: $stderr, random: SecureRandom)
    @env = env
    @runner = runner
    @stdout = stdout
    @stderr = stderr
    @random = random
  end

  def setup
    values = validate_inputs
    runner_temp
    cleanup if File.exist?(state_path)
    original_search_list = current_search_list

    work_dir = File.join(runner_temp, "terminal-signing-#{random_hex(16)}")
    keychain = File.join(work_dir, 'signing.keychain-db')
    profile = "terminal-notary-#{random_hex(16)}"
    state_written = false

    begin
      # Do not reuse a pre-existing path, even though a random collision is
      # exceptionally unlikely. The explicit chmod fixes the inherited mode.
      Dir.mkdir(work_dir, 0o700)
      File.chmod(0o700, work_dir)
      state = {
        'work_dir' => work_dir,
        'keychain' => keychain,
        'search_list' => original_search_list
      }
      write_state(state)
      state_written = true

      keychain_password = random_password
      @runner.run(['security', 'create-keychain', '-p', keychain_password, keychain])
      @runner.run(['security', 'set-keychain-settings', '-lut', '21600', keychain])
      @runner.run(['security', 'unlock-keychain', '-p', keychain_password, keychain])
      set_search_list([keychain] + state.fetch('search_list'))

      application_certificate = write_secret(work_dir, 'application.p12', values.fetch('application_certificate'))
      installer_certificate = write_secret(work_dir, 'installer.p12', values.fetch('installer_certificate'))
      notary_key = write_secret(work_dir, 'notary-key.p8', values.fetch('notary_key'))

      import_certificate(application_certificate, values.fetch('application_password'), keychain)
      File.delete(application_certificate)
      import_certificate(installer_certificate, values.fetch('installer_password'), keychain)
      File.delete(installer_certificate)
      @runner.run(['security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s', '-k', keychain_password, keychain])
      @runner.run([
        'xcrun', 'notarytool', 'store-credentials', profile,
        '--key', notary_key,
        '--key-id', values.fetch('notary_key_id'),
        '--issuer', values.fetch('notary_issuer_id'),
        '--keychain', keychain
      ])
      File.delete(notary_key)

      # These are the only setup stdout lines, so callers can append directly
      # to GITHUB_ENV without risking a secret being written there.
      @stdout.puts "APPLE_NOTARY_PROFILE=#{profile}"
      @stdout.puts "APPLE_SIGNING_KEYCHAIN=#{keychain}"
    rescue StandardError
      if state_written
        cleanup_after_setup_failure
      else
        File.delete(state_path) if File.exist?(state_path)
        FileUtils.rm_rf(work_dir)
      end
      raise
    end
  end

  def cleanup
    state = read_state
    return unless state

    validate_state!(state)
    errors = []
    begin
      set_search_list(state.fetch('search_list'))
    rescue StandardError => error
      errors << error
    end

    begin
      @runner.run(['security', 'delete-keychain', state.fetch('keychain')])
    rescue StandardError => error
      # A previous interrupted cleanup may already have deleted it. In that
      # case the missing file is a successful, idempotent outcome.
      errors << error if File.exist?(state.fetch('keychain'))
    end

    begin
      FileUtils.rm_rf(state.fetch('work_dir'))
    rescue StandardError => error
      errors << error
    end

    if errors.empty?
      File.delete(state_path) if File.exist?(state_path)
    else
      raise Error, 'release signing cleanup failed'
    end
  end

  private

  def validate_inputs
    missing = REQUIRED_ENV.select { |name| @env[name].nil? || @env[name].empty? }
    raise Error, "missing required environment variables: #{missing.join(', ')}" unless missing.empty?

    {
      'application_certificate' => decode_base64('APPLE_APPLICATION_CERTIFICATE_BASE64'),
      'application_password' => @env.fetch('APPLE_APPLICATION_CERTIFICATE_PASSWORD'),
      'installer_certificate' => decode_base64('APPLE_INSTALLER_CERTIFICATE_BASE64'),
      'installer_password' => @env.fetch('APPLE_INSTALLER_CERTIFICATE_PASSWORD'),
      'notary_key' => decode_base64('APPLE_NOTARY_KEY_BASE64'),
      'notary_key_id' => @env.fetch('APPLE_NOTARY_KEY_ID'),
      'notary_issuer_id' => @env.fetch('APPLE_NOTARY_ISSUER_ID')
    }
  end

  def decode_base64(name)
    decoded = Base64.strict_decode64(@env.fetch(name))
    raise ArgumentError if decoded.empty?

    decoded
  rescue ArgumentError
    raise Error, "#{name} must contain non-empty strict base64"
  end

  def runner_temp
    value = @env['RUNNER_TEMP']
    raise Error, 'RUNNER_TEMP must be set' if value.nil? || value.empty?

    path = File.expand_path(value)
    raise Error, 'RUNNER_TEMP must name an existing directory' unless Dir.exist?(path)

    path
  end

  def state_path
    File.join(runner_temp, STATE_NAME)
  end

  def current_search_list
    output = @runner.output(['security', 'list-keychains', '-d', 'user'])
    paths = Shellwords.shellsplit(output).map { |path| File.expand_path(path) }
    raise Error, 'security keychain search list is empty' if paths.empty?

    paths
  rescue ArgumentError
    raise Error, 'security returned an invalid keychain search list'
  end

  def set_search_list(paths)
    @runner.run(['security', 'list-keychains', '-d', 'user', '-s', *paths])
  end

  def write_state(state)
    write_private_file(state_path, JSON.generate(state))
  end

  def read_state
    return unless File.exist?(state_path)

    JSON.parse(File.binread(state_path))
  rescue JSON::ParserError
    raise Error, 'release signing state is invalid'
  end

  def validate_state!(state)
    work_dir = state['work_dir']
    keychain = state['keychain']
    search_list = state['search_list']
    expected_parent = "#{runner_temp}/"
    unless work_dir.is_a?(String) && File.expand_path(work_dir).start_with?(expected_parent) &&
           File.basename(work_dir).start_with?('terminal-signing-') &&
           keychain == File.join(work_dir, 'signing.keychain-db') &&
           search_list.is_a?(Array) && search_list.all? { |path| path.is_a?(String) }
      raise Error, 'release signing state is invalid'
    end
  end

  def write_secret(directory, name, contents)
    path = File.join(directory, name)
    write_private_file(path, contents)
    path
  end

  def write_private_file(path, contents)
    # The file is never created with the default (potentially group-readable)
    # mode. O_EXCL also prevents replacing a path that was not made by this run.
    File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.binmode
      file.write(contents)
    end
  rescue StandardError
    File.delete(path) if File.exist?(path)
    raise
  end

  def import_certificate(path, password, keychain)
    @runner.run([
      'security', 'import', path, '-k', keychain, '-P', password,
      '-T', '/usr/bin/codesign', '-T', '/usr/bin/pkgbuild', '-T', '/usr/bin/productsign'
    ])
  end

  def random_password
    # Hex avoids shell/metacharacter surprises while retaining 256 bits of entropy.
    random_hex(32)
  end

  def random_hex(bytes)
    @random.hex(bytes)
  end

  def cleanup_after_setup_failure
    cleanup
  rescue StandardError
    # Preserve the setup error. State remains for an explicit later cleanup if
    # restoring the user's search list failed.
  end
end

if $PROGRAM_NAME == __FILE__
  command = ARGV.fetch(0, nil)
  signing = ReleaseSigning.new
  begin
    case command
    when 'setup' then signing.setup
    when 'cleanup' then signing.cleanup
    else raise ReleaseSigning::Error, 'usage: release_signing.rb setup|cleanup'
    end
  rescue ReleaseSigning::Error => error
    warn "release signing: #{error.message}"
    exit 1
  end
end
