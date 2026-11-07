import Foundation

@main enum SwiftGraphicsTests {
  static let context = KittyGraphicsContext(alternate: false, row: 3, column: 5, cellWidth: 8, cellHeight: 16)
  static func packet(_ header: String, _ bytes: [UInt8]) -> Data {
    Data("G\(header);\(Data(bytes).base64EncodedString())".utf8)
  }
  static func main() {
    let store = KittyGraphicsStore()
    let first = store.consume(packet("a=T,t=d,f=24,s=2,v=1,i=7,p=9,c=3,r=2,C=1", [255, 0, 0, 0, 255, 0]), context: context, now: 1)
    precondition(first.advance?.0 == 3 && first.advance?.1 == 2)
    precondition(String(data: first.reply!, encoding: .utf8)!.contains("i=7,p=9;OK"))
    let placement = store.visible(alternate: false).only!
    precondition(placement.image == 7 && placement.width == 2 && placement.height == 1)
    precondition(store.imageRGBA(id: 7, generation: placement.generation) == Data([255, 0, 0, 255, 0, 255, 0, 255]))

    let original = Array(repeating: UInt8(42), count: 12)
    let encoded = Data(original).base64EncodedString()
    let cut = encoded.index(encoded.startIndex, offsetBy: 8)
    _ = store.consume(Data("Ga=T,t=d,f=32,s=3,v=1,i=8,m=1;\(encoded[..<cut])".utf8), context: context, now: 2)
    precondition(store.visible(alternate: false).count == 1)
    _ = store.consume(Data("Gm=0;\(encoded[cut...])".utf8), context: context, now: 3)
    let loaded = store.visible(alternate: false).first { $0.image == 8 }!
    precondition(store.imageRGBA(id: 8, generation: loaded.generation) == Data(original))

    // zlib transport is decoded only into the declared image extent.
    let zlib: [UInt8] = [120, 1, 99, 100, 98, 102, 1, 0, 0, 24, 0, 11]
    let zlibResult = store.consume(packet("a=T,t=d,f=32,s=1,v=1,o=z,i=10", zlib), context: context, now: 4)
    guard let zipped = store.visible(alternate: false).first(where: { $0.image == 10 }) else {
      fatalError(String(data: zlibResult.reply ?? Data(), encoding: .utf8) ?? "zlib placement missing")
    }
    precondition(store.imageRGBA(id: 10, generation: zipped.generation) == Data([1, 2, 3, 4]))
    let bomb = store.consume(packet("a=t,t=d,f=32,s=1,v=1,o=z,i=11", Array(repeating: 0, count: 4096)), context: context, now: 4)
    precondition(String(data: bomb.reply!, encoding: .utf8)!.contains("EINVAL"))

    _ = store.consume(Data("Ga=d,d=I,i=7".utf8), context: context, now: 5)
    precondition(store.visible(alternate: false).allSatisfy { $0.image != 7 })
    precondition(store.imageRGBA(id: 7, generation: placement.generation) == nil)

    let invalid = store.consume(Data("Ga=T,t=f,f=24,s=1,v=1,i=1;AQID".utf8), context: context, now: 6)
    precondition(String(data: invalid.reply!, encoding: .utf8)!.contains("ENOTSUP"))
    print("PASS Swift Kitty graphics: direct/zlib RGBA, atomic chunks, placement and deletion")
  }
}

private extension Array {
  var only: Element? { count == 1 ? self[0] : nil }
}
