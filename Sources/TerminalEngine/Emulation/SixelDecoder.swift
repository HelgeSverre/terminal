import Foundation

/// Decodes a Sixel picture as its bytes arrive: what follows the `q` of
/// `DCS P1 ; P2 ; P3 q` up to the string terminator.
///
/// The picture grows as data is drawn, within fixed limits; a picture that
/// would pass them is cut off there, never grown without bound. Pixels no
/// sixel touched stay transparent, so the terminal's background shows.
final class SixelDecoder {
  static let maximumDimension = 4096
  static let maximumBytes = 16 * 1024 * 1024
  /// The VT340's sixteen colors, used until the picture defines its own.
  private static let defaultPalette: [UInt32] = [
    0x000000, 0x3333cc, 0xcc2121, 0x33cc33, 0xcc33cc, 0x33cccc, 0xcccc33, 0x878787,
    0x424242, 0x545499, 0x994242, 0x549954, 0x995499, 0x549999, 0x999954, 0xcccccc,
  ]

  private var palette = [UInt32](repeating: 0, count: 256)
  private var pixels: [UInt32] = []   // 0xAABBGGRR, row-major, `stride` wide
  private var stride = 0
  private var rows = 0
  private var width = 0   // The extent drawn or declared so far.
  private var height = 0
  private var x = 0
  private var y = 0
  private var color: UInt32
  /// The command being read and its numeric parameters.
  private var command: UInt8 = 0
  private var parameters: [Int] = []
  private var number: Int?
  private var overflowed = false

  init() {
    for (index, value) in Self.defaultPalette.enumerated() { palette[index] = Self.pixel(value) }
    for index in 16..<256 { palette[index] = Self.pixel(Self.defaultPalette[index % 16]) }
    color = palette[0]
  }

  private static func pixel(_ rgb: UInt32) -> UInt32 {
    0xff00_0000 | (rgb & 0xff) << 16 | (rgb & 0xff00) | (rgb >> 16) & 0xff
  }

  /// Takes one byte of the picture. Bytes outside the Sixel alphabet are
  /// skipped, as the format says.
  func push(_ byte: UInt8) {
    switch byte {
    case 0x30...0x39:
      guard command != 0 else { return }
      // A parameter; kept small enough that arithmetic on it cannot overflow.
      number = min(1_000_000, (number ?? 0) * 10 + Int(byte - 0x30))
    case 0x3b:
      guard command != 0 else { return }
      appendParameter(number ?? 0); number = nil
    default:
      finishCommand()
      switch byte {
      case 0x21, 0x22, 0x23:                   // ! repeat, " raster, # color
        command = byte; parameters.removeAll(keepingCapacity: true)
      case 0x24: x = 0                         // $ carriage return
      case 0x2d: x = 0; y = min(Self.maximumDimension, y + 6) // - new line of sixels
      case 0x3f...0x7e: draw(byte - 0x3f, count: 1)
      default: break
      }
    }
  }

  private func appendParameter(_ value: Int) {
    // Color definitions have the most parameters: index, space and three
    // components. Ignore excess fields without retaining an unbounded list.
    if parameters.count < 5 { parameters.append(value) }
  }

  /// Applies a command once its parameters are complete. A repeat is
  /// applied by the data byte that follows it.
  private func finishCommand() {
    guard command != 0 else { return }
    if let number { appendParameter(number) }
    number = nil
    defer { if command != 0x21 { command = 0; parameters.removeAll(keepingCapacity: true) } }
    switch command {
    case 0x22:
      // Raster attributes: pixel aspect, then the picture's width and height.
      // The declared size is the picture's size, even where nothing is drawn.
      if parameters.count >= 4, reserve(width: parameters[2], height: parameters[3]) {
        width = max(width, min(parameters[2], stride)); height = max(height, min(parameters[3], rows))
      }
    case 0x23:
      guard let index = parameters.first, index < 256 else { return }
      if parameters.count >= 5 {
        let a = parameters[2], b = parameters[3], c = parameters[4]
        palette[index] = parameters[1] == 1 ? Self.hls(a, b, c) : Self.rgb(a, b, c)
      }
      color = palette[index]
    default: break
    }
  }

  private static func rgb(_ red: Int, _ green: Int, _ blue: Int) -> UInt32 {
    func byte(_ percent: Int) -> UInt32 { UInt32(min(100, max(0, percent)) * 255 / 100) }
    return 0xff00_0000 | byte(blue) << 16 | byte(green) << 8 | byte(red)
  }
  /// Hue in degrees with blue at 0, as the VT340 has it; lightness and
  /// saturation in percent.
  private static func hls(_ hue: Int, _ lightness: Int, _ saturation: Int) -> UInt32 {
    let h = Double((hue + 240) % 360) / 360, l = Double(min(100, max(0, lightness))) / 100
    let s = Double(min(100, max(0, saturation))) / 100
    guard s > 0 else { let gray = Int((l * 100).rounded()); return rgb(gray, gray, gray) }
    let q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q
    func channel(_ value: Double) -> Int {
      var t = value
      if t < 0 { t += 1 }
      if t > 1 { t -= 1 }
      let result: Double
      if t < 1.0 / 6 { result = p + (q - p) * 6 * t }
      else if t < 0.5 { result = q }
      else if t < 2.0 / 3 { result = p + (q - p) * (2.0 / 3 - t) * 6 }
      else { result = p }
      return Int((result * 100).rounded())
    }
    return rgb(channel(h + 1.0 / 3), channel(h), channel(h - 1.0 / 3))
  }

  private func draw(_ bits: UInt8, count: Int) {
    var repeatCount = count
    if command == 0x21 {
      if let number { appendParameter(number) }
      number = nil
      repeatCount = max(1, parameters.first ?? 1)
      command = 0; parameters.removeAll(keepingCapacity: true)
    }
    let end = min(Self.maximumDimension, x + repeatCount)
    defer { x = min(Self.maximumDimension, x + repeatCount) }
    guard bits != 0, x < end, y < Self.maximumDimension else { return }
    guard reserve(width: end, height: y + 6) else { return }
    for bit in 0..<6 where bits & (1 << bit) != 0 {
      let row = y + bit
      guard row < rows else { break }
      let start = row * stride + x
      for index in start..<(start + end - x) { pixels[index] = color }
      height = max(height, row + 1)
    }
    width = max(width, end)
  }

  /// Makes the picture at least this large, within the limits. Returns
  /// false when there is no room for the pixels asked for.
  @discardableResult private func reserve(width wanted: Int, height wantedHeight: Int) -> Bool {
    let newWidth = min(Self.maximumDimension, max(wanted, 0))
    let newHeight = min(Self.maximumDimension, max(wantedHeight, 0))
    if newWidth <= stride && newHeight <= rows { return true }
    // Grow in steps, so a picture drawn sixel by sixel is not copied each time.
    let targetStride = max(stride, newWidth <= stride ? stride : max(newWidth, min(Self.maximumDimension, stride * 2)))
    let targetRows = max(rows, newHeight <= rows ? rows : max(newHeight, min(Self.maximumDimension, rows * 2)))
    guard targetStride * targetRows * 4 <= Self.maximumBytes else {
      // Try the exact size before giving up.
      let exactStride = max(stride, newWidth), exactRows = max(rows, newHeight)
      guard exactStride * exactRows * 4 <= Self.maximumBytes else { overflowed = true; return false }
      resize(stride: exactStride, rows: exactRows)
      return true
    }
    resize(stride: targetStride, rows: targetRows)
    return true
  }
  private func resize(stride newStride: Int, rows newRows: Int) {
    guard newStride != stride || newRows != rows else { return }
    var grown = [UInt32](repeating: 0, count: newStride * newRows)
    if stride > 0 {
      for row in 0..<rows {
        grown.replaceSubrange((row * newStride)..<(row * newStride + stride),
                              with: pixels[(row * stride)..<((row + 1) * stride)])
      }
    }
    pixels = grown; stride = newStride; rows = newRows
  }

  /// The picture, or nil when nothing was drawn.
  func finish() -> (width: Int, height: Int, rgba: Data)? {
    finishCommand()
    guard width > 0, height > 0 else { return nil }
    var rgba = Data(count: width * height * 4)
    rgba.withUnsafeMutableBytes { raw in
      let out = raw.bindMemory(to: UInt32.self)
      for row in 0..<height {
        for column in 0..<width { out[row * width + column] = pixels[row * stride + column].littleEndian }
      }
    }
    return (width, height, rgba)
  }
}
