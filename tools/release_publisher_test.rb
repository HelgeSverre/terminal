# frozen_string_literal: true

require 'base64'
require 'json'
require 'minitest/autorun'
require 'tmpdir'
require_relative 'release_publisher'

class ReleasePublisherTest < Minitest::Test
  SHA = 'a' * 40

  def test_validate_accepts_matching_tag_and_writes_safe_metadata
    with_fixture do |root, runner|
      output = File.join(root, 'metadata.json')
      github_output = File.join(root, 'github-output')
      metadata = publisher(root, runner, tag_environment.merge('GITHUB_OUTPUT' => github_output)).validate(output: output)

      assert metadata['publish']
      assert_equal 'v1.2.3', metadata['tag']
      assert_equal metadata, JSON.parse(File.read(output))
      assert_includes File.read(github_output), "version=1.2.3\ntag=v1.2.3\npublish=true"
      assert_includes File.read(github_output), "source_sha=#{SHA}"
    end
  end

  def test_validate_rejects_red_tag_or_unreachable_source
    with_fixture do |root, runner|
      error = assert_raises(ReleasePublisher::Error) do
        publisher(root, runner, tag_environment.merge('GITHUB_REF' => 'refs/tags/v1.2.4')).validate(output: File.join(root, 'metadata.json'))
      end
      assert_includes error.message, 'refs/tags/v1.2.3'

      runner.ancestor = false
      error = assert_raises(ReleasePublisher::Error) do
        publisher(root, runner, tag_environment).validate(output: File.join(root, 'metadata.json'))
      end
      assert_includes error.message, 'merge-base'
    end
  end

  def test_manual_main_is_green_but_never_authorizes_publish
    with_fixture do |root, runner|
      metadata = publisher(root, runner, {
        'GITHUB_EVENT_NAME' => 'workflow_dispatch', 'GITHUB_REF' => 'refs/heads/main', 'GITHUB_SHA' => SHA
      }).validate(output: File.join(root, 'metadata.json'))
      refute metadata['publish']
      assert_equal 'v1.2.3', metadata['tag']
    end
  end

  def test_manifest_and_publish_are_idempotent
    with_fixture do |root, runner|
      metadata_path, release_dir = prepared_release(root, runner)
      publisher(root, runner, publishing_environment).publish(metadata: metadata_path, release_dir: release_dir)
      publisher(root, runner, publishing_environment).publish(metadata: metadata_path, release_dir: release_dir)

      release = runner.release
      refute release['isDraft']
      assert_equal %w[HelgeTerminal-1.2.3-arm64.pkg HelgeTerminal-1.2.3-arm64.zip SHA256SUMS release-manifest.json], release['assets'].map { |asset| asset['name'] }.sort
      assert_equal '1.2.3', runner.cask_version
      assert_equal 1, runner.puts
    end
  end

  def test_publish_refuses_integrity_conflict_before_tap_mutation
    with_fixture do |root, runner|
      metadata_path, release_dir = prepared_release(root, runner)
      runner.release = {
        'tagName' => 'v1.2.3', 'targetCommitish' => SHA, 'isDraft' => false,
        'assets' => [{ 'name' => 'HelgeTerminal-1.2.3-arm64.zip', 'digest' => "sha256:#{'0' * 64}", 'size' => 3 }]
      }
      error = assert_raises(ReleasePublisher::Error) do
        publisher(root, runner, publishing_environment).publish(metadata: metadata_path, release_dir: release_dir)
      end
      assert_includes error.message, 'different SHA256'
      assert_equal 0, runner.puts
    end
  end

  def test_publish_fails_closed_when_release_lookup_is_not_a_404
    with_fixture do |root, runner|
      metadata_path, release_dir = prepared_release(root, runner)
      runner.release_error = 'HTTP 502: GitHub is unavailable'

      error = assert_raises(ReleasePublisher::Error) do
        publisher(root, runner, publishing_environment).publish(metadata: metadata_path, release_dir: release_dir)
      end
      assert_includes error.message, 'cannot read GitHub release'
      assert_nil runner.release
      assert_equal 0, runner.puts
    end
  end

  def test_partial_draft_is_completed_without_replacing_verified_asset
    with_fixture do |root, runner|
      metadata_path, release_dir = prepared_release(root, runner)
      zip = File.join(release_dir, 'HelgeTerminal-1.2.3-arm64.zip')
      runner.release = {
        'tagName' => 'v1.2.3', 'targetCommitish' => SHA, 'isDraft' => true,
        'assets' => [{ 'name' => File.basename(zip), 'size' => File.size(zip),
                       'digest' => "sha256:#{Digest::SHA256.file(zip).hexdigest}" }]
      }
      publisher(root, runner, publishing_environment).publish(metadata: metadata_path, release_dir: release_dir)

      refute runner.release['isDraft']
      assert_equal 4, runner.release['assets'].length
    end
  end

  def test_publish_binds_metadata_to_the_current_checkout_and_event
    with_fixture do |root, runner|
      metadata_path, release_dir = prepared_release(root, runner)
      metadata = JSON.parse(File.read(metadata_path))
      metadata['source_sha'] = 'b' * 40
      File.write(metadata_path, JSON.generate(metadata))
      publisher(root, runner, publishing_environment).manifest(metadata: metadata_path, release_dir: release_dir)

      error = assert_raises(ReleasePublisher::Error) do
        publisher(root, runner, publishing_environment).publish(metadata: metadata_path, release_dir: release_dir)
      end
      assert_includes error.message, 'GITHUB_SHA'
      assert_nil runner.release
    end
  end

  def test_tap_cas_reloads_and_skips_newer_version
    with_fixture do |root, runner|
      metadata_path, release_dir = prepared_release(root, runner)
      runner.cask_text = runner.cask_text.sub('version "0.2.2"', 'version "9.0.0"')
      publisher(root, runner, publishing_environment).publish(metadata: metadata_path, release_dir: release_dir)
      assert_equal 0, runner.puts
      assert_equal '9.0.0', runner.cask_version
    end
  end

  def test_tap_cas_retries_after_a_concurrent_update
    with_fixture do |root, runner|
      metadata_path, release_dir = prepared_release(root, runner)
      runner.fail_first_tap_put = true
      publisher(root, runner, publishing_environment).publish(metadata: metadata_path, release_dir: release_dir)

      assert_equal '1.2.3', runner.cask_version
      assert_equal 2, runner.puts
    end
  end

  def test_manifest_allows_known_private_release_outputs
    with_fixture do |root, runner|
      metadata_path, release_dir = prepared_release(root, runner)
      Dir.mkdir(File.join(release_dir, 'Helge Terminal.app'))
      File.write(File.join(release_dir, 'notary-app.json'), '{}')
      File.write(File.join(release_dir, 'notary-pkg.json'), '{}')
      File.write(File.join(release_dir, 'release-metadata.json'), '{}')

      manifest = publisher(root, runner, publishing_environment).manifest(metadata: metadata_path, release_dir: release_dir)
      assert_equal %w[HelgeTerminal-1.2.3-arm64.pkg HelgeTerminal-1.2.3-arm64.zip], manifest['assets'].map { |asset| asset['name'] }.sort
    end
  end

  private

  def tag_environment
    { 'GITHUB_EVENT_NAME' => 'push', 'GITHUB_REF' => 'refs/tags/v1.2.3', 'GITHUB_SHA' => SHA }
  end

  def publishing_environment = tag_environment.merge('GITHUB_TOKEN' => 'release-token', 'TAP_GITHUB_TOKEN' => 'tap-token')

  def publisher(root, runner, env)
    ReleasePublisher.new(root: root, runner: runner.method(:call), env: env)
  end

  def prepared_release(root, runner)
    metadata = File.join(root, 'metadata.json')
    release_dir = File.join(root, 'dist/release')
    Dir.mkdir(File.join(root, 'dist'))
    Dir.mkdir(release_dir)
    File.binwrite(File.join(release_dir, 'HelgeTerminal-1.2.3-arm64.zip'), 'zip')
    File.binwrite(File.join(release_dir, 'HelgeTerminal-1.2.3-arm64.pkg'), 'pkg')
    publish_env = publishing_environment
    tool = publisher(root, runner, publish_env)
    tool.validate(output: metadata)
    tool.manifest(metadata: metadata, release_dir: release_dir)
    [metadata, release_dir]
  end

  def with_fixture
    Dir.mktmpdir('release-publisher-') do |root|
      FileUtils.mkdir_p(File.join(root, 'Resources/Terminal'))
      File.write(File.join(root, 'Resources/Terminal/Info.plist'), <<~PLIST)
        <plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>1.2.3</string></dict></plist>
      PLIST
      yield root, FakeGitHub.new
    end
  end

  class FakeGitHub
    attr_accessor :ancestor, :release, :cask_text, :fail_first_tap_put, :release_error
    attr_reader :puts

    def initialize
      @ancestor = true
      @release = nil
      @puts = 0
      @cask_text = <<~CASK
        cask "helge-terminal" do
          version "0.2.2"
          sha256 "#{'1' * 64}"
          url "https://example.invalid/old.zip"

          livecheck do
            url "https://github.com/HelgeSverre/homebrew-tap/releases"
            regex(/helge-terminal-v?(\\d+(?:\\.\\d+)+)/i)
          end
        end
      CASK
    end

    def cask_version = @cask_text[/version "([^"]+)"/, 1]

    def call(argv, env:)
      return git(argv) if argv.first == 'git'
      return gh(argv, env) if argv.first == 'gh'

      ['', 'unexpected command', 1]
    end

    private

    def git(argv)
      case argv[1..]
      when ['rev-parse', 'v1.2.3^{}'] then [SHA + "\n", '', 0]
      when ['rev-parse', 'HEAD'] then [SHA + "\n", '', 0]
      when ['merge-base', '--is-ancestor', SHA, 'origin/main'] then ['', '', @ancestor ? 0 : 1]
      else ['', "unexpected git #{argv.inspect}", 1]
      end
    end

    def gh(argv, env)
      return ['', 'missing token', 1] if env['GH_TOKEN'].to_s.empty?
      case argv[1..3]
      when ['release', 'view', 'v1.2.3']
        return ['', @release_error, 1] if @release_error
        @release ? [JSON.generate(@release), '', 0] : ['', 'not found', 1]
      when ['release', 'create', 'v1.2.3']
        @release ||= { 'tagName' => 'v1.2.3', 'targetCommitish' => SHA, 'isDraft' => true, 'assets' => [] }
        ['', '', 0]
      when ['release', 'upload', 'v1.2.3']
        paths = argv.drop(4).take_while { |entry| entry != '--repo' }
        paths.each do |path|
          @release['assets'] << { 'name' => File.basename(path), 'size' => File.size(path),
                                  'digest' => "sha256:#{Digest::SHA256.file(path).hexdigest}" }
        end
        ['', '', 0]
      when ['release', 'edit', 'v1.2.3']
        @release['isDraft'] = false
        ['', '', 0]
      when ['api', 'repos/HelgeSverre/homebrew-tap/contents/Casks/helge-terminal.rb?ref=main']
        [JSON.generate('content' => Base64.strict_encode64(@cask_text), 'sha' => 'old-sha'), '', 0]
      when ['api', '--method', 'PUT']
        @puts += 1
        if @fail_first_tap_put
          @fail_first_tap_put = false
          @cask_text = @cask_text.sub('version "0.2.2"', 'version "0.3.0"')
          return ['', 'sha does not match', 1]
        end
        content = argv.find { |item| item.start_with?('content=') }.delete_prefix('content=')
        @cask_text = Base64.decode64(content)
        ['', '', 0]
      else
        ['', "unexpected gh #{argv.inspect}", 1]
      end
    end
  end
end
