#!/usr/bin/env ruby
# frozen_string_literal: true

# Loopback-only, deterministic Responses SSE fixture. Request bodies and
# headers are discarded and never written to provenance.
require 'digest'
require 'json'
require 'socket'
require 'timeout'

class TUIStressProvider
  RESPONSE = <<~MARKDOWN.freeze
    TUI_STRESS_RESPONSE

    # Streamed resize fixture

    **bold** _italic_ and `inline-code` render while this response streams.

    ```swift
    let path = "/tmp/tui-stress/猫/combining-café.txt"
    print("TUI_STRESS_RESPONSE")
    ```

    | field | rendered value |
    | --- | --- |
    | path | `/tmp/tui-stress/猫` |
    | link | https://example.test/tui-stress |
    | text | 中 文 · café · 👩‍💻 |

    URL: https://example.test/tui-stress
    TUI_STRESS_RESPONSE
    MARKDOWN

  MAX_BODY_BYTES = 1 * 1024 * 1024
  MAX_HEADER_BYTES = 64 * 1024
  MAX_RESPONSE_BYTES = 16 * 1024
  DEFAULT_LIFETIME_SECONDS = 90
  DEFAULT_MAX_REQUESTS = 8
  DEFAULT_SLOW_MS = 12

  def self.self_test
    events = stream_events(response_id: 'resp_tui_stress_001')
    expected_types = ['response.created', 'response.output_item.added', 'response.content_part.added'] +
      Array.new(chunks.length, 'response.output_text.delta') +
      ['response.output_text.done', 'response.content_part.done', 'response.output_item.done', 'response.completed']
    raise 'missing response lifecycle' unless events.map { |event| event.fetch('type') } == expected_types
    raise 'non-monotonic sequence numbers' unless events.map { |event| event.fetch('sequence_number') } == (1..events.length).to_a
    text = events.select { |event| event['type'] == 'response.output_text.delta' }.map { |event| event.fetch('delta') }.join
    raise 'response text changed' unless text == RESPONSE
    raise 'response exceeds fixture bound' unless RESPONSE.bytesize <= MAX_RESPONSE_BYTES
    puts 'PASS tui-stress provider: deterministic Responses SSE event lifecycle and Unicode-safe chunks'
  end

  def self.chunks
    @chunks ||= RESPONSE.each_char.each_slice(18).map(&:join).freeze
  end

  def self.stream_events(response_id:)
    item_id = "msg_#{response_id.delete_prefix('resp_')}"
    response = response_object(response_id: response_id, status: 'in_progress', output: [])
    part = { 'type' => 'output_text', 'text' => '', 'annotations' => [], 'logprobs' => [] }
    item = { 'id' => item_id, 'status' => 'in_progress', 'type' => 'message', 'role' => 'assistant', 'content' => [] }
    events = [
      { 'type' => 'response.created', 'response' => response },
      { 'type' => 'response.output_item.added', 'output_index' => 0, 'item' => item },
      { 'type' => 'response.content_part.added', 'item_id' => item_id, 'output_index' => 0, 'content_index' => 0, 'part' => part }
    ]
    chunks.each { |delta| events << { 'type' => 'response.output_text.delta', 'item_id' => item_id, 'output_index' => 0, 'content_index' => 0, 'delta' => delta, 'logprobs' => [] } }
    complete_part = part.merge('text' => RESPONSE)
    complete_item = item.merge('status' => 'completed', 'content' => [complete_part])
    events.concat([
      { 'type' => 'response.output_text.done', 'item_id' => item_id, 'output_index' => 0, 'content_index' => 0, 'text' => RESPONSE, 'logprobs' => [] },
      { 'type' => 'response.content_part.done', 'item_id' => item_id, 'output_index' => 0, 'content_index' => 0, 'part' => complete_part },
      { 'type' => 'response.output_item.done', 'output_index' => 0, 'item' => complete_item },
      { 'type' => 'response.completed', 'response' => response_object(response_id: response_id, status: 'completed', output: [complete_item]) }
    ])
    events.each_with_index { |event, index| event['sequence_number'] = index + 1 }
  end

  def self.response_object(response_id:, status:, output:)
    {
      'id' => response_id, 'object' => 'response', 'created_at' => 1, 'status' => status,
      'completed_at' => status == 'completed' ? 1 : nil, 'error' => nil, 'incomplete_details' => nil,
      'instructions' => nil, 'max_output_tokens' => nil, 'model' => 'fixture-model', 'output' => output,
      'parallel_tool_calls' => false, 'previous_response_id' => nil,
      'reasoning' => { 'effort' => nil, 'summary' => nil }, 'store' => false, 'temperature' => 1,
      'text' => { 'format' => { 'type' => 'text' } }, 'tool_choice' => 'auto', 'tools' => [],
      'top_p' => 1, 'truncation' => 'disabled', 'usage' => nil, 'user' => nil, 'metadata' => {}
    }
  end

  def initialize(environment: ENV, clock: Process)
    @port_file = File.expand_path(environment.fetch('TERMINAL_TUI_STRESS_PROVIDER_PORT_FILE'))
    @slow_ms = integer(environment, 'TERMINAL_TUI_STRESS_PROVIDER_SLOW_MS', DEFAULT_SLOW_MS, 0..1000)
    @max_requests = integer(environment, 'TERMINAL_TUI_STRESS_PROVIDER_MAX_REQUESTS', DEFAULT_MAX_REQUESTS, 1..32)
    @lifetime_seconds = integer(environment, 'TERMINAL_TUI_STRESS_PROVIDER_LIFETIME_SECONDS', DEFAULT_LIFETIME_SECONDS, 1..300)
    raise 'provider port file already exists; use a unique fixture path' if File.exist?(@port_file)
    raise 'provider port-file parent directory is missing' unless Dir.exist?(File.dirname(@port_file))
    @clock = clock; @requests = []; @workers = []; @accepted = 0; @lock = Mutex.new
    @stopping = false; @server = TCPServer.new('127.0.0.1', 0); @port = @server.addr[1]; @started = monotonic
    %w[INT TERM HUP].each { |signal| Signal.trap(signal) { @stopping = true } }
  end

  def serve
    write_provenance('listening')
    deadline = monotonic + @lifetime_seconds
    until @stopping || monotonic >= deadline
      readable = IO.select([@server], nil, nil, [[deadline - monotonic, 0].max, 0.25].min)
      next unless readable
      socket = @server.accept_nonblock(exception: false)
      next unless socket.is_a?(TCPSocket)
      slot = reserve_request
      if slot
        @workers << Thread.new(socket, slot) { |client, request_slot| handle(client, request_slot) }
        @workers.reject!(&:alive?)
      else
        socket.close
        break
      end
    end
  ensure
    final_status = @stopping ? 'stopped' : 'complete'
    @stopping = true
    @server.close unless @server.closed?
    @workers.each(&:join)
    write_provenance(final_status)
  end

  private

  def integer(environment, key, default, range)
    value = Integer(environment.fetch(key, default.to_s), 10)
    raise "#{key} must be within #{range}" unless range.cover?(value)
    value
  rescue ArgumentError
    raise "#{key} must be an integer within #{range}"
  end

  def reserve_request
    @lock.synchronize do
      return nil if @accepted >= @max_requests
      @accepted += 1
    end
  end

  def handle(socket, slot)
    started = monotonic
    request_line, headers = Timeout.timeout(3) { read_headers(socket) }
    method, target, version = request_line.split(' ', 3)
    raise 'invalid HTTP version' unless version == 'HTTP/1.1'
    body_bytes = discard_body(socket, headers)
    if method == 'POST' && target == '/v1/responses'
      response_id = format('resp_tui_stress_%03d', slot)
      stream(socket, response_id)
      record(method, target, body_bytes, response_id, 200, started)
    elsif method == 'GET' && target == '/v1/models'
      json(socket, 200, { 'object' => 'list', 'data' => [{ 'id' => 'fixture-model', 'object' => 'model', 'created' => 1, 'owned_by' => 'tui-stress' }] })
      record(method, target, body_bytes, nil, 200, started)
    else
      json(socket, 404, { 'error' => { 'message' => 'local fixture route not found', 'type' => 'invalid_request_error' } })
      record(method, target, body_bytes, nil, 404, started)
    end
  rescue StandardError => error
    json(socket, 400, { 'error' => { 'message' => 'local fixture rejected malformed request', 'type' => 'invalid_request_error' } }) rescue nil
    record('invalid', 'invalid', 0, nil, 400, started, error.class.name)
  ensure
    socket.close unless socket.closed?
  end

  def read_headers(socket)
    total = 0; request_line = socket.gets("\r\n")&.strip
    raise 'missing request line' if request_line.nil? || request_line.empty?
    headers = {}
    loop do
      line = socket.gets("\r\n"); raise 'truncated request headers' unless line
      break if line == "\r\n"
      total += line.bytesize; raise 'request headers exceed fixture bound' if total > MAX_HEADER_BYTES
      name, value = line.split(':', 2); raise 'malformed request header' unless name && value
      headers[name.downcase] = value.strip
    end
    [request_line, headers]
  end

  def discard_body(socket, headers)
    raise 'chunked request bodies are not accepted by this fixture' if headers['transfer-encoding']
    length = Integer(headers.fetch('content-length', '0'), 10)
    raise 'request body exceeds fixture bound' unless (0..MAX_BODY_BYTES).cover?(length)
    remaining = length
    while remaining.positive?
      bytes = socket.read([remaining, 16_384].min); raise 'truncated request body' unless bytes
      remaining -= bytes.bytesize
    end
    length
  rescue KeyError, ArgumentError
    raise 'invalid request content length'
  end

  def stream(socket, response_id)
    socket.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\nX-Accel-Buffering: no\r\n\r\n")
    self.class.stream_events(response_id: response_id).each do |event|
      socket.write("event: #{event.fetch('type')}\n")
      socket.write("data: #{JSON.generate(event)}\n\n")
      socket.flush
      sleep(@slow_ms / 1000.0) if event['type'] == 'response.output_text.delta' && @slow_ms.positive? && !@stopping
    end
  end

  def json(socket, status, body)
    payload = JSON.generate(body)
    socket.write("HTTP/1.1 #{status} #{status == 200 ? 'OK' : 'Not Found'}\r\nContent-Type: application/json\r\nContent-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
  end

  def record(method, path, body_bytes, response_id, status, started, error = nil)
    @lock.synchronize do
      @requests << { 'method' => method, 'path' => path, 'body_bytes' => body_bytes, 'response_id' => response_id,
                     'status' => status, 'duration_ms' => ((monotonic - started) * 1000).round(3), 'error' => error }.compact
      write_provenance('listening')
    end
  end

  def write_provenance(status)
    payload = {
      'protocol' => 'responses-sse-fixture-v1', 'status' => status, 'pid' => Process.pid, 'host' => '127.0.0.1', 'port' => @port,
      'response_identity' => 'TUI_STRESS_RESPONSE', 'response_sha256' => Digest::SHA256.hexdigest(RESPONSE), 'response_bytes' => RESPONSE.bytesize,
      'event_count' => self.class.stream_events(response_id: 'resp_tui_stress_001').length, 'slow_ms' => @slow_ms,
      'max_requests' => @max_requests, 'lifetime_seconds' => @lifetime_seconds, 'request_count' => @requests.length,
      'requests' => @requests, 'started_monotonic' => @started, 'updated_monotonic' => monotonic
    }
    mode = File.exist?(@port_file) ? 'r+' : File::WRONLY | File::CREAT | File::EXCL
    File.open(@port_file, mode, 0o600) { |file| file.rewind; file.truncate(0); file.write(JSON.generate(payload)); file.flush }
  end

  def monotonic = @clock.clock_gettime(Process::CLOCK_MONOTONIC)
end

case ARGV
when ['--self-test'] then TUIStressProvider.self_test
when [] then TUIStressProvider.new.serve
else
  warn 'Usage: TERMINAL_TUI_STRESS_PROVIDER_PORT_FILE=/absolute/fixture/provider.json ruby tools/tui_stress/provider.rb [--self-test]'
  exit 2
end
