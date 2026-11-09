#!/usr/bin/env ruby
# frozen_string_literal: true

# Deliberately small release boundary: build jobs write files, this program checks
# them before it asks GitHub to make any change.
require 'base64'
require 'digest'
require 'json'
require 'open3'
require 'optparse'
require 'tempfile'
require 'tmpdir'

class ReleasePublisher
  class Error < StandardError; end

  TERMINAL_REPOSITORY = 'HelgeSverre/terminal'
  TAP_REPOSITORY = 'HelgeSverre/homebrew-tap'
  TAP_CASK_PATH = 'Casks/helge-terminal.rb'
  ASSET_SUFFIXES = %w[zip pkg].freeze
  LOCAL_RELEASE_OUTPUTS = ['Helge Terminal.app', 'notary-app.json', 'notary-pkg.json',
                           'release-metadata.json', 'release-manifest.json', 'SHA256SUMS'].freeze

  def initialize(root: File.expand_path('..', __dir__), env: ENV, runner: nil)
    @root = root
    @env = env
    @runner = runner || method(:open3_run)
  end

  def validate(output:, github_output: @env['GITHUB_OUTPUT'])
    version = bundle_version
    tag = "v#{version}"
    event = @env.fetch('GITHUB_EVENT_NAME', '')
    ref = @env.fetch('GITHUB_REF', '')
    source_sha = @env.fetch('GITHUB_SHA', '')
    fail! 'GITHUB_SHA must be a full commit SHA' unless source_sha.match?(/\A[0-9a-f]{40}\z/i)

    publish = case event
              when 'push'
                fail! "release push must be refs/tags/#{tag}" unless ref == "refs/tags/#{tag}"
                tag_sha = git('rev-parse', "#{tag}^{}").strip
                fail! "tag #{tag} does not resolve to GITHUB_SHA" unless tag_sha.casecmp?(source_sha)
                true
              when 'workflow_dispatch'
                fail! 'manual release validation is allowed only from main' unless ref == 'refs/heads/main'
                false
              else
                fail! "unsupported GitHub event #{event.inspect}"
              end
    run_git('merge-base', '--is-ancestor', source_sha, 'origin/main')

    metadata = {
      'schema' => 1, 'version' => version, 'tag' => tag, 'source_sha' => source_sha,
      'publish' => publish, 'event_name' => event, 'ref' => ref
    }
    write_json(output, metadata)
    append_github_output(github_output, metadata) if github_output && !github_output.empty?
    metadata
  end

  def manifest(metadata:, release_dir:)
    metadata = read_metadata(metadata)
    assets = expected_assets(metadata, release_dir)
    payload = {
      'schema' => 1, 'version' => metadata.fetch('version'), 'tag' => metadata.fetch('tag'),
      'source_sha' => metadata.fetch('source_sha'),
      'assets' => assets.map { |path| asset_record(path) }
    }
    write_json(File.join(release_dir, 'release-manifest.json'), payload)
    sums = payload['assets'].map { |asset| "#{asset['sha256']}  #{asset['name']}" }.join("\n") + "\n"
    File.write(File.join(release_dir, 'SHA256SUMS'), sums)
    payload
  end

  def publish(metadata:, release_dir:)
    metadata = read_metadata(metadata)
    fail! 'metadata does not authorize publishing' unless metadata['publish'] == true
    verify_source!(metadata)
    manifest = verify_manifest!(metadata, release_dir)
    assets = manifest.fetch('assets')
    names = assets.map { |asset| asset.fetch('name') } + %w[release-manifest.json SHA256SUMS]
    # All verification above happens before this first GitHub mutation.
    release = find_release(metadata.fetch('tag'))
    if release
      verify_release!(release, metadata, assets, release_dir, allow_missing: true)
    else
      create_draft_release(metadata)
      release = find_release(metadata.fetch('tag'))
      fail! 'GitHub did not return newly created release' unless release
    end

    upload_missing_assets(release, metadata.fetch('tag'), names, release_dir)
    release = find_release(metadata.fetch('tag'))
    verify_release!(release, metadata, assets, release_dir)
    publish_release(release, metadata.fetch('tag')) if release['isDraft']
    update_tap(metadata, assets.find { |asset| asset['name'].end_with?('.zip') })
    true
  end

  private

  def bundle_version
    plist = File.join(@root, 'Resources', 'Terminal', 'Info.plist')
    fail! "missing #{plist}" unless File.file?(plist)
    value = File.read(plist)[
      /<key>\s*CFBundleShortVersionString\s*<\/key>\s*<string>\s*([^<\s]+)\s*<\/string>/m,
      1
    ].to_s
    fail! 'CFBundleShortVersionString must be X.Y.Z' unless value.match?(/\A\d+\.\d+\.\d+\z/)
    value
  end

  def expected_assets(metadata, release_dir)
    version = metadata.fetch('version')
    names = ASSET_SUFFIXES.map { |suffix| "HelgeTerminal-#{version}-arm64.#{suffix}" }
    fail! "missing release directory #{release_dir}" unless Dir.exist?(release_dir)
    actual = Dir.children(release_dir)
    unexpected = actual - names - LOCAL_RELEASE_OUTPUTS
    fail! "unexpected release output: #{unexpected.join(', ')}" unless unexpected.empty?
    missing = names - actual
    fail! "missing release assets: #{missing.join(', ')}" unless missing.empty?
    names.map do |name|
      path = File.join(release_dir, name)
      fail! "missing regular asset #{name}" unless File.file?(path) && !File.symlink?(path)
      path
    end
  end

  def asset_record(path)
    { 'name' => File.basename(path), 'sha256' => Digest::SHA256.file(path).hexdigest, 'bytes' => File.size(path) }
  end

  def verify_manifest!(metadata, release_dir)
    manifest_path = File.join(release_dir, 'release-manifest.json')
    sums_path = File.join(release_dir, 'SHA256SUMS')
    fail! 'release manifest is missing' unless File.file?(manifest_path) && File.file?(sums_path)
    manifest = JSON.parse(File.read(manifest_path))
    %w[version tag source_sha].each { |key| fail! "manifest #{key} differs from metadata" unless manifest[key] == metadata[key] }
    expected = expected_assets(metadata, release_dir).map { |path| asset_record(path) }
    fail! 'release manifest assets differ from files' unless manifest['assets'] == expected
    expected_sums = expected.map { |asset| "#{asset['sha256']}  #{asset['name']}" }.join("\n") + "\n"
    fail! 'SHA256SUMS differs from release manifest' unless File.binread(sums_path) == expected_sums
    manifest
  rescue JSON::ParserError => error
    fail! "invalid release manifest: #{error.message}"
  end

  def verify_source!(metadata)
    source = metadata.fetch('source_sha')
    fail! 'metadata source_sha is invalid' unless source.match?(/\A[0-9a-f]{40}\z/i)
    fail! 'publish requires a tag push event' unless @env['GITHUB_EVENT_NAME'] == 'push'
    fail! "publish ref must be refs/tags/#{metadata['tag']}" unless @env['GITHUB_REF'] == "refs/tags/#{metadata['tag']}"
    fail! 'metadata source_sha differs from GITHUB_SHA' unless @env['GITHUB_SHA'].to_s.casecmp?(source)
    head = git('rev-parse', 'HEAD').strip
    fail! 'metadata source_sha differs from checkout HEAD' unless head.casecmp?(source)
    tag_sha = git('rev-parse', "#{metadata['tag']}^{}").strip
    fail! 'metadata source_sha differs from release tag' unless tag_sha.casecmp?(source)
    run_git('merge-base', '--is-ancestor', source, 'origin/main')
  end

  def find_release(tag)
    result = command('gh', 'release', 'view', tag, '--repo', TERMINAL_REPOSITORY,
                     '--json', 'tagName,isDraft,targetCommitish,assets')
    unless result[:success]
      return nil if result[:stderr].match?(/\b(not found|http 404)\b/i)

      fail! "cannot read GitHub release #{tag}: #{result[:stderr]}"
    end

    JSON.parse(result[:stdout])
  rescue JSON::ParserError => error
    fail! "GitHub returned invalid release JSON: #{error.message}"
  end

  def create_draft_release(metadata)
    Tempfile.create(['release-notes-', '.md']) do |notes|
      notes.write("Helge Terminal #{metadata.fetch('tag')}\n")
      notes.flush
      run_command('gh', 'release', 'create', metadata.fetch('tag'), '--repo', TERMINAL_REPOSITORY,
                  '--target', metadata.fetch('source_sha'), '--draft', '--title', metadata.fetch('tag'),
                  '--notes-file', notes.path)
    end
  end

  def verify_release!(release, metadata, assets, release_dir, allow_missing: false)
    fail! "release tag differs: #{release['tagName'].inspect}" unless release['tagName'] == metadata['tag']
    target = release['targetCommitish'].to_s
    fail! "release target differs: #{target}" unless target.empty? || target.casecmp?(metadata['source_sha'])
    remote = release.fetch('assets', {}).each_with_object({}) { |asset, out| out[asset['name']] = asset }
    files = assets + %w[release-manifest.json SHA256SUMS].map { |name| asset_record(File.join(release_dir, name)) }
    files.each do |asset|
      next unless remote[asset['name']]
      verify_remote_asset!(remote[asset['name']], asset, metadata['tag'], release_dir)
    end
    missing = files.map { |asset| asset['name'] } - remote.keys
    fail! "release is missing assets: #{missing.join(', ')}" if !allow_missing && !missing.empty?
    unexpected = remote.keys - files.map { |asset| asset['name'] }
    fail! "release contains unexpected assets: #{unexpected.join(', ')}" unless unexpected.empty?
  end

  def verify_remote_asset!(remote, asset, tag, release_dir)
    digest = remote['digest'].to_s.sub(/\Asha256:/, '')
    if digest.match?(/\A[0-9a-f]{64}\z/i)
      fail! "remote asset #{asset['name']} has a different SHA256" unless digest.casecmp?(asset['sha256'])
    elsif !remote_asset_matches_file?(remote, File.join(release_dir, asset['name']), tag)
      fail! "cannot verify remote asset #{asset['name']}"
    end
    fail! "remote asset #{asset['name']} has a different size" if remote['size'] && remote['size'].to_i != asset['bytes']
  end

  def remote_asset_matches_file?(remote, path, tag)
    return false unless remote['name'] == File.basename(path)
    Dir.mktmpdir('release-asset-') do |directory|
      result = command('gh', 'release', 'download', tag, '--repo', TERMINAL_REPOSITORY,
                       '--pattern', remote['name'], '--dir', directory, '--clobber')
      copy = File.join(directory, remote['name'])
      result[:success] && File.file?(copy) &&
        Digest::SHA256.file(copy).hexdigest.casecmp?(Digest::SHA256.file(path).hexdigest)
    end
  end

  def upload_missing_assets(release, tag, names, release_dir)
    present = release.fetch('assets', []).map { |asset| asset['name'] }
    missing = names - present
    return if missing.empty?

    run_command('gh', 'release', 'upload', tag, *missing.map { |name| File.join(release_dir, name) }, '--repo', TERMINAL_REPOSITORY)
  end

  def publish_release(release, tag)
    run_command('gh', 'release', 'edit', tag, '--repo', TERMINAL_REPOSITORY, '--draft=false') if release['isDraft']
  end

  def update_tap(metadata, zip_asset)
    fail! 'ZIP asset missing from manifest' unless zip_asset
    3.times do
      current = get_tap_cask
      text = Base64.decode64(current.fetch('content').delete("\n"))
      state = cask_state(text)
      comparison = compare_versions(state.fetch('version'), metadata.fetch('version'))
      return if comparison.positive?
      if comparison.zero?
        return if state['url'] == release_url(metadata, zip_asset) &&
                  state['sha256'].casecmp?(zip_asset['sha256']) && terminal_livecheck?(text)
        fail! "tap already has a different #{metadata['version']} cask"
      end
      replacement = replace_cask(text, metadata, zip_asset)
      result = tap_command('gh', 'api', '--method', 'PUT', "repos/#{TAP_REPOSITORY}/contents/#{TAP_CASK_PATH}",
                       '-f', "message=Update Helge Terminal to #{metadata['tag']}",
                       '-f', "content=#{Base64.strict_encode64(replacement)}", '-f', "sha=#{current.fetch('sha')}", '-f', 'branch=main')
      return if result[:success]
    end
    fail! 'tap cask changed concurrently; refusing to overwrite it'
  end

  def get_tap_cask
    result = tap_command('gh', 'api', "repos/#{TAP_REPOSITORY}/contents/#{TAP_CASK_PATH}?ref=main")
    return JSON.parse(result.fetch(:stdout)) if result[:success]

    fail! "command failed: gh api tap cask\n#{result[:stderr]}"
  rescue JSON::ParserError => error
    fail! "GitHub returned invalid cask JSON: #{error.message}"
  end

  def cask_state(text)
    version = text[/^\s*version\s+"([^"]+)"/, 1]
    url = text[/^\s*url\s+"([^"]+)"/, 1]
    sha = text[/^\s*sha256\s+"([0-9a-f]{64})"/i, 1]
    fail! 'tap cask has no simple version, URL, and SHA256 fields' unless version && url && sha
    { 'version' => version, 'url' => url, 'sha256' => sha }
  end

  def replace_cask(text, metadata, zip_asset)
    updated = text.sub(/^\s*version\s+"[^"]+"/, "  version \"#{metadata['version']}\"")
                  .sub(/^\s*url\s+"[^"]+"/, "  url \"#{release_url(metadata, zip_asset)}\"")
                  .sub(/^\s*sha256\s+"[0-9a-f]{64}"/i, "  sha256 \"#{zip_asset['sha256']}\"")
    livecheck = <<~RUBY.chomp
      livecheck do
        url "https://github.com/#{TERMINAL_REPOSITORY}/releases"
        regex(/^v?(\\d+(?:\\.\\d+)+)$/i)
        strategy :github_releases
      end
    RUBY
    replacement = "  #{livecheck.gsub("\n", "\n  ")}"
    unless updated.sub!(/^  livecheck do\n.*?^  end$/m, replacement)
      fail! 'tap cask has no replaceable livecheck block'
    end
    updated
  end

  def release_url(metadata, zip_asset)
    "https://github.com/#{TERMINAL_REPOSITORY}/releases/download/#{metadata['tag']}/#{zip_asset['name']}"
  end

  def terminal_livecheck?(text)
    text.match?(%r{livecheck do\s+url "https://github\.com/HelgeSverre/terminal/releases"\s+regex\(/\^v\?\(\\d\+\(\?:\\\.\\d\+\)\+\)\$/i\)\s+strategy :github_releases\s+end}m)
  end

  def compare_versions(left, right)
    left.split('.').map(&:to_i) <=> right.split('.').map(&:to_i)
  end

  def read_metadata(path)
    metadata = JSON.parse(File.read(path))
    %w[version tag source_sha publish].each { |key| fail! "metadata missing #{key}" unless metadata.key?(key) }
    fail! 'metadata version is invalid' unless metadata['version'].match?(/\A\d+\.\d+\.\d+\z/)
    fail! 'metadata tag does not match version' unless metadata['tag'] == "v#{metadata['version']}"
    metadata
  rescue Errno::ENOENT
    fail! "missing metadata #{path}"
  rescue JSON::ParserError => error
    fail! "invalid metadata: #{error.message}"
  end

  def append_github_output(path, metadata)
    File.open(path, 'a') do |file|
      file.puts "version=#{metadata['version']}"
      file.puts "tag=#{metadata['tag']}"
      file.puts "publish=#{metadata['publish']}"
      file.puts "source_sha=#{metadata['source_sha']}"
    end
  end

  def write_json(path, object)
    File.write(path, JSON.pretty_generate(object) + "\n")
  end

  def git(*args) = run_command('git', *args).fetch(:stdout)
  def run_git(*args) = run_command('git', *args)

  def run_command(*argv)
    result = command(*argv)
    return result if result[:success]
    fail! "command failed: #{argv.join(' ')}\n#{result[:stderr]}"
  end

  def command(*argv)
    output, error, status = @runner.call(argv, env: argv.first == 'gh' ? github_env : {})
    { stdout: output.to_s, stderr: error.to_s, success: status.respond_to?(:success?) ? status.success? : status == 0 }
  end

  def tap_command(*argv)
    token = @env['TAP_GITHUB_TOKEN']
    fail! 'TAP_GITHUB_TOKEN is required to update the Homebrew tap' if token.to_s.empty?
    output, error, status = @runner.call(argv, env: { 'GH_TOKEN' => token })
    { stdout: output.to_s, stderr: error.to_s, success: status.respond_to?(:success?) ? status.success? : status == 0 }
  end

  def github_env
    token = @env['GITHUB_TOKEN'] || @env['GH_TOKEN']
    fail! 'GITHUB_TOKEN or GH_TOKEN is required for GitHub commands' if token.to_s.empty?
    { 'GH_TOKEN' => token }
  end

  def open3_run(argv, env:)
    Open3.capture3(env, *argv, chdir: @root)
  end

  def fail!(message) = raise(Error, message)
end

if $PROGRAM_NAME == __FILE__
  begin
    command = ARGV.shift
    options = { release_dir: 'dist/release' }
    parser = OptionParser.new do |opts|
      opts.on('--output PATH') { |value| options[:output] = value }
      opts.on('--metadata PATH') { |value| options[:metadata] = value }
      opts.on('--release-dir PATH') { |value| options[:release_dir] = value }
    end
    parser.parse!(ARGV)
    publisher = ReleasePublisher.new
    case command
    when 'validate'
      abort parser.to_s unless options[:output]
      publisher.validate(output: options[:output])
    when 'manifest'
      abort parser.to_s unless options[:metadata]
      publisher.manifest(metadata: options[:metadata], release_dir: options[:release_dir])
    when 'publish'
      abort parser.to_s unless options[:metadata]
      publisher.publish(metadata: options[:metadata], release_dir: options[:release_dir])
    else
      abort "usage: #{$PROGRAM_NAME} validate|manifest|publish [options]"
    end
  rescue ReleasePublisher::Error => error
    warn "release publisher: #{error.message}"
    exit 1
  end
end
