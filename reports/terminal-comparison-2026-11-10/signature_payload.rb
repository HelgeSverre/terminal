require 'digest'
require 'json'

abort 'Usage: signature_payload.rb COMPILER_EXECUTABLE PACKAGED_EXECUTABLE' unless ARGV.length == 2
result = {}
payloads = []
%w[compiler packaged].zip(ARGV).each do |name, path|
  bytes = File.binread(path)
  abort 'Expected a little-endian 64-bit Mach-O executable' unless bytes.unpack1('L<') == 0xfeedfacf
  count, command_bytes = bytes.byteslice(16, 8).unpack('L<2')
  cursor = 32
  signature = linkedit = nil
  count.times do
    kind, size = bytes.byteslice(cursor, 8).unpack('L<2')
    abort 'Invalid load command' unless size >= 8 && cursor + size <= 32 + command_bytes
    signature = [cursor, *bytes.byteslice(cursor + 8, 8).unpack('L<2')] if kind == 0x1d
    if kind == 0x19 && bytes.byteslice(cursor + 8, 16).delete("\0") == '__LINKEDIT'
      linkedit = cursor
    end
    cursor += size
  end
  abort 'Missing signature bookkeeping' unless signature && linkedit
  abort 'Expected signature at end of file' unless signature[1] + signature[2] == bytes.bytesize
  payload = bytes.byteslice(0, signature[1])
  # Normalize only signature location/length and the containing segment sizes.
  # All other headers, instructions, data, symbols, and relocation bytes remain.
  payload[signature[0] + 8, 8] = [0, 0].pack('L<2')
  payload[linkedit + 32, 8] = [0].pack('Q<')
  payload[linkedit + 48, 8] = [0].pack('Q<')
  payloads << payload
  result[name] = { path: path, bytes: bytes.bytesize, sha256: Digest::SHA256.hexdigest(bytes),
    signature_offset: signature[1], signature_bytes: signature[2],
    normalized_payload_sha256: Digest::SHA256.hexdigest(payload) }
end
result['identical_except_signature_and_linkedit_sizes'] = payloads[0] == payloads[1]
puts JSON.pretty_generate(result)
abort 'Packaged payload differs' unless result['identical_except_signature_and_linkedit_sizes']
