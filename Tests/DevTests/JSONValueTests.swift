import Foundation
import Testing
@testable import dev

@Suite struct JSONValueTests {
  @Test("ordered json: text is kept through parsing and writing") func textIsKeptThroughParsingAndWriting() throws {
    let source = #"{"b":1,"a":[true,null,-0,12345678901234567890,1.50,"é\n\u0001😀/"],"b":{"z":{},"y":[]}}"#
    let value = try JSONValue(parsing: source)
    #expect(value.compact == "{\"b\":{\"z\":{},\"y\":[]},\"a\":[true,null,0,12345678901234567890,1.5,\"é\\n\\u0001😀/\"]}",
            "got \(value.compact)")
    #expect(value.sorted.compact.hasPrefix(#"{"a":[true"#) && value.sorted.compact.hasSuffix(#""b":{"y":[],"z":{}}}"#), "sorted")
    #expect(value.pretty == "{\n  \"b\": {\n    \"z\": {},\n    \"y\": []\n  },\n  \"a\": [\n    true,\n    null,\n    0,\n"
              + "    12345678901234567890,\n    1.5,\n    \"é\\n\\u0001😀/\"\n  ]\n}", "got \(value.pretty)")
    for broken in ["", "{", "[1,]", "{\"a\":1,}", "01", "1.", "nul", "\"a", "[1] 2", "{'a':1}", "NaN"] {
      #expect((try? JSONValue(parsing: broken)) == nil, "accepted \(broken)")
    }
  }

  @Test("ordered json: fractions are written as Ruby writes them") func fractionsAreWrittenAsRubyWrites() throws {
    let expected: [(Double, String)] = [
      (0, "0.0"), (-0.0, "-0.0"), (1, "1.0"), (120, "120.0"), (0.1, "0.1"), (12.34, "12.34"), (-2.5, "-2.5"),
      (0.0001, "0.0001"), (0.00001, "1.0e-05"), (1.5e-7, "1.5e-07"), (999999999999999.9, "999999999999999.9"), (1e15, "1.0e+15"),
      (9007199254740992, "9.007199254740992e+15"), (1e16, "1.0e+16"), (1.2345e22, "1.2345e+22"), (5e-324, "5.0e-324"),
      (123456.789, "123456.789"), (1e100, "1.0e+100"),
    ]
    for (value, text) in expected { #expect(JSONValue.decimal(value) == text, "\(value) gave \(JSONValue.decimal(value))") }
  }

  @Test("ordered json: a parsed report is written with sorted keys and its numbers keep their kind") func aParsedReportIsWrittenWithSortedKeys() throws {
    let parsed = try JSONSerialization.jsonObject(with: Data(#"{"b":2.0,"a":[2,true,null,"x/y"],"c":{}}"#.utf8))
    let compact = try JSONValue(sortingKeysOf: parsed).compact
    #expect(compact == #"{"a":[2,true,null,"x/y"],"b":2.0,"c":{}}"#, "got \(compact)")
    let built: [String: Any] = ["rate": 4.0 / 2, "runs": 3, "passed": false, "list": [Int](), "nothing": NSNull()]
    let pretty = try JSONValue(sortingKeysOf: built).pretty
    #expect(pretty == "{\n  \"list\": [],\n  \"nothing\": null,\n  \"passed\": false,\n  \"rate\": 2.0,\n  \"runs\": 3\n}",
            "got \(pretty)")
    #expect((try? JSONValue(sortingKeysOf: ["rate": Double.infinity])) == nil, "an infinite number was written")
    #expect((try? JSONValue(sortingKeysOf: ["date": Date()])) == nil, "a value JSON has no form for was written")
  }
}
