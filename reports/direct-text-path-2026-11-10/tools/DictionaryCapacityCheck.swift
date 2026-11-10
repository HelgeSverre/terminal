// How does Dictionary<UInt64, Int>.capacity evolve? Find a closed form and verify it.
func modelCapacity(holding count: Int) -> Int {
  // Smallest power-of-two bucket count whose 3/4 load holds `count` keys.
  guard count > 0 else { return 0 }
  var buckets = 2
  while buckets * 3 / 4 < count { buckets *= 2 }
  return buckets * 3 / 4
}
var mismatches = 0
// 1. Growth by insertion from empty.
var d: [UInt64: Int] = [:]
var model = 0
for key in 1...200_000 {
  if d.count == model { model = modelCapacity(holding: d.count + 1) }
  d[UInt64(key)] = key
  if d.capacity != model { mismatches += 1; if mismatches < 5 { print("grow", key, d.capacity, model) } }
}
// 2. reserveCapacity / minimumCapacity.
for n in 0...5000 {
  let r = Dictionary<UInt64, Int>(minimumCapacity: n)
  if r.capacity != modelCapacity(holding: n) { mismatches += 1; if mismatches < 10 { print("min", n, r.capacity, modelCapacity(holding: n)) } }
  var e: [UInt64: Int] = [:]; e.reserveCapacity(n)
  if e.capacity != modelCapacity(holding: n) { mismatches += 1; if mismatches < 10 { print("reserve", n, e.capacity, modelCapacity(holding: n)) } }
}
// 3. Removal and removeAll(keepingCapacity:) keep capacity; removeAll() drops it; a shared copy keeps it on write.
let before = d.capacity
for key in 1...150_000 { d.removeValue(forKey: UInt64(key)) }
if d.capacity != before { mismatches += 1; print("remove shrank") }
let copy = d; d[999_999_999] = 1
if d.capacity != before || copy.capacity != before { mismatches += 1; print("cow changed", d.capacity, before) }
d.removeAll(keepingCapacity: true)
if d.capacity != before { mismatches += 1; print("keeping changed") }
d.removeAll()
if d.capacity != 0 { mismatches += 1; print("removeAll kept", d.capacity) }
// 4. reserve below current capacity is a no-op; reserve on a part-filled dictionary.
var f: [UInt64: Int] = [:]; for key in 1...100 { f[UInt64(key)] = 0 }
let c100 = f.capacity; f.reserveCapacity(10)
if f.capacity != c100 { mismatches += 1; print("reserve shrank") }
f.reserveCapacity(1000)
if f.capacity != modelCapacity(holding: 1000) { mismatches += 1; print("reserve grow", f.capacity) }
print("mismatches", mismatches)
