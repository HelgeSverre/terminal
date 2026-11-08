import AppKit
import ApplicationServices
import Foundation

// An external, read-only accessibility probe for one specifically launched
// disposable test PID. It does not enumerate applications, locate apps by
// name, or send AX actions/sets.

private struct ArgumentError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

private struct ProbeError: Error, CustomStringConvertible {
  let stage: String
  let status: AXError
  var description: String { "\(stage) failed with AXError(rawValue: \(status.rawValue))" }
}

private struct Arguments {
  let pid: pid_t
  let identifier: String
  let reportPath: String?

  init() throws {
    let values = Array(CommandLine.arguments.dropFirst())
    if values == ["--help"] || values == ["-h"] {
      print("Usage: AccessibilityProbe --pid <owned-test-pid> --identifier <AXIdentifier-or-stable-prefix> [--report <path>]")
      print("Queries one exact test PID read-only and never requests Accessibility permission.")
      exit(EXIT_SUCCESS)
    }
    var pidValue: pid_t?
    var identifierValue: String?
    var reportValue: String?
    var index = 0
    while index < values.count {
      guard index + 1 < values.count else { throw ArgumentError("Missing value for \(values[index])") }
      let value = values[index + 1]
      switch values[index] {
      case "--pid":
        guard let parsed = Int32(value), parsed > 0 else { throw ArgumentError("--pid must be a positive integer") }
        pidValue = pid_t(parsed)
      case "--identifier": identifierValue = value
      case "--report": reportValue = value
      default: throw ArgumentError("Unknown argument: \(values[index])")
      }
      index += 2
    }
    guard let pidValue else { throw ArgumentError("--pid is required") }
    guard let identifierValue, !identifierValue.isEmpty else { throw ArgumentError("--identifier is required") }
    pid = pidValue
    identifier = identifierValue
    reportPath = reportValue
  }
}

private func copyAttribute(_ element: AXUIElement, _ attribute: String) throws -> Any {
  var value: CFTypeRef?
  let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
  guard status == .success, let value else { throw ProbeError(stage: "AX attribute \(attribute)", status: status) }
  return value
}

private func optionalAttribute(_ element: AXUIElement, _ attribute: String) -> Any? {
  try? copyAttribute(element, attribute)
}

private func copyParameterizedAttribute(_ element: AXUIElement, _ attribute: String, _ parameter: CFTypeRef)
  throws -> Any
{
  var value: CFTypeRef?
  let status = AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, parameter, &value)
  guard status == .success, let value else {
    throw ProbeError(stage: "AX parameterized attribute \(attribute)", status: status)
  }
  return value
}

private func rangeParameter(_ range: NSRange) -> AXValue? {
  var value = CFRange(location: range.location, length: range.length)
  return AXValueCreate(.cfRange, &value)
}

private func describeElement(_ element: AXUIElement) -> [String: Any] {
  var pid: pid_t = 0
  AXUIElementGetPid(element, &pid)
  var result: [String: Any] = ["kind": "AXUIElement", "pid": Int(pid)]
  for attribute in [
    kAXRoleAttribute, kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXURLAttribute,
  ] {
    if let value = optionalAttribute(element, attribute as String) {
      result[attribute as String] = jsonValue(value)
    }
  }
  let position = geometryAttribute(element, attribute: kAXPositionAttribute, type: .cgPoint)
  let size = geometryAttribute(element, attribute: kAXSizeAttribute, type: .cgSize)
  if let position {
    result["AXPosition"] = position
  }
  if let size {
    result["AXSize"] = size
  }
  if let position, let size,
    let x = position["x"], let y = position["y"],
    let width = size["width"], let height = size["height"]
  {
    result["frame"] = ["x": x, "y": y, "width": width, "height": height]
  }
  var actions: CFArray?
  let actionStatus = AXUIElementCopyActionNames(element, &actions)
  if actionStatus == .success, let actions {
    result["actions"] = (actions as [AnyObject]).compactMap { $0 as? String }
  } else {
    result["action_names_error"] = "AXError(rawValue: \(actionStatus.rawValue))"
  }
  return result
}

private func geometryAttribute(_ element: AXUIElement, attribute: String, type: AXValueType) -> [String: Any]? {
  guard let raw = optionalAttribute(element, attribute),
    CFGetTypeID(raw as AnyObject) == AXValueGetTypeID()
  else { return nil }
  let value = raw as! AXValue
  switch type {
  case .cgPoint:
    var point = CGPoint.zero
    guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
    return ["x": point.x, "y": point.y]
  case .cgSize:
    var size = CGSize.zero
    guard AXValueGetValue(value, .cgSize, &size) else { return nil }
    return ["width": size.width, "height": size.height]
  default:
    return nil
  }
}

private func isAXElement(_ value: Any) -> Bool {
  let object = value as AnyObject
  return CFGetTypeID(object) == AXUIElementGetTypeID()
}

private func jsonValue(_ value: Any) -> Any {
  if isAXElement(value) { return describeElement(value as! AXUIElement) }
  let object = value as AnyObject
  if CFGetTypeID(object) == CGColor.typeID {
    let color = value as! CGColor
    return [
      "kind": "CGColor", "color_space": color.colorSpace?.name as String? ?? "unknown",
      "components": color.components ?? [],
    ]
  }
  switch value {
  case let color as NSColor:
    guard let converted = color.usingColorSpace(.sRGB) else {
      return ["kind": "NSColor", "description": color.description]
    }
    return [
      "kind": "NSColor", "color_space": "sRGB", "red": converted.redComponent,
      "green": converted.greenComponent, "blue": converted.blueComponent, "alpha": converted.alphaComponent,
    ]
  case let font as NSFont:
    return ["kind": "NSFont", "name": font.fontName, "point_size": font.pointSize]
  case let url as URL:
    return ["kind": "URL", "value": url.absoluteString]
  case let string as String: return string
  case let number as NSNumber: return number
  case let array as [Any]: return array.map(jsonValue)
  case let dictionary as [AnyHashable: Any]:
    return Dictionary(uniqueKeysWithValues: dictionary.map { (String(describing: $0.key), jsonValue($0.value)) })
  default:
    return ["kind": String(reflecting: type(of: value)), "description": String(describing: value)]
  }
}

private func describeAttributedString(_ attributed: NSAttributedString) -> [String: Any] {
  let fullRange = NSRange(location: 0, length: attributed.length)
  var runs: [[String: Any]] = []
  attributed.enumerateAttributes(in: fullRange, options: []) { attributes, range, _ in
    let serialized = Dictionary(uniqueKeysWithValues: attributes.map {
      ($0.key.rawValue, jsonValue($0.value))
    })
    runs.append([
      "range": ["location": range.location, "length": range.length], "attributes": serialized,
    ])
  }
  return ["string": attributed.string, "utf16_length": attributed.length, "runs": runs]
}

private func findPane(_ application: AXUIElement, identifier: String) throws -> AXUIElement {
  var queue: [(element: AXUIElement, depth: Int)] = [(application, 0)]
  var visited = 0
  while !queue.isEmpty, visited < 4_096 {
    let current = queue.removeFirst()
    visited += 1
    let role = optionalAttribute(current.element, kAXRoleAttribute as String) as? String
    let candidate = optionalAttribute(current.element, kAXIdentifierAttribute as String) as? String
    if role == kAXTextAreaRole as String, let candidate,
      candidate == identifier || candidate.hasPrefix(identifier)
    {
      return current.element
    }
    guard current.depth < 16,
      let children = optionalAttribute(current.element, kAXChildrenAttribute as String) as? [AXUIElement]
    else { continue }
    queue.append(contentsOf: children.map { ($0, current.depth + 1) })
  }
  throw ArgumentError("No AXTextArea with identifier \(identifier.debugDescription) under the exact PID")
}

private func readOnlyValue(_ element: AXUIElement) throws -> [String: Any] {
  let value = try copyAttribute(element, kAXValueAttribute as String)
  guard let text = value as? String else {
    throw ArgumentError("AXValue was \(String(reflecting: type(of: value))), not String")
  }
  var settable = DarwinBoolean(false)
  let status = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
  guard status == .success else { throw ProbeError(stage: "AXValue settable check", status: status) }
  return ["text": text, "utf16_length": (text as NSString).length, "settable": settable.boolValue]
}

private func queryRange(_ element: AXUIElement, value: String) throws -> [String: Any] {
  let range = NSRange(location: 0, length: min((value as NSString).length, 512))
  guard let parameter = rangeParameter(range) else { throw ArgumentError("Could not construct CFRange") }
  let plain = try copyParameterizedAttribute(element, kAXStringForRangeParameterizedAttribute as String, parameter)
  let attributed = try copyParameterizedAttribute(
    element, kAXAttributedStringForRangeParameterizedAttribute as String, parameter)
  guard let plainText = plain as? String else {
    throw ArgumentError("AXStringForRange was \(String(reflecting: type(of: plain))), not String")
  }
  guard let attributedText = attributed as? NSAttributedString else {
    throw ArgumentError("AXAttributedStringForRange was \(String(reflecting: type(of: attributed))), not NSAttributedString")
  }
  guard plainText == attributedText.string else { throw ArgumentError("Plain and attributed range strings differed") }
  return [
    "range": ["location": range.location, "length": range.length], "plain_string": plainText,
    "attributed_string": describeAttributedString(attributedText),
  ]
}

private func styleRanges(_ element: AXUIElement, length: Int) -> [[String: Any]] {
  guard length > 0 else { return [] }
  var ranges: [[String: Any]] = []
  var seen = Set<String>()
  for index in 0..<min(length, 512) {
    do {
      let result = try copyParameterizedAttribute(
        element, kAXStyleRangeForIndexParameterizedAttribute as String, NSNumber(value: index))
      guard CFGetTypeID(result as AnyObject) == AXValueGetTypeID() else {
        throw ArgumentError("AXStyleRangeForIndex was \(String(reflecting: type(of: result))), not AXValue")
      }
      let axRange = result as! AXValue
      var cfRange = CFRange()
      guard AXValueGetValue(axRange, .cfRange, &cfRange) else {
        throw ArgumentError("AXStyleRangeForIndex AXValue was not a CFRange")
      }
      let key = "\(cfRange.location):\(cfRange.length)"
      if seen.insert(key).inserted {
        ranges.append(["index": index, "range": ["location": cfRange.location, "length": cfRange.length]])
      }
    } catch {
      return [["error": String(describing: error), "index": index]]
    }
  }
  return ranges
}

private func assertions(
  value: [String: Any], rangeQuery: [String: Any], styleRanges: [[String: Any]]
) -> [String: Bool] {
  let attributed = rangeQuery["attributed_string"] as? [String: Any] ?? [:]
  let plain = rangeQuery["plain_string"] as? String
  let runs = attributed["runs"] as? [[String: Any]] ?? []
  var hasColor = false
  var hasFontDictionary = false
  var link: [String: Any]?
  for run in runs {
    guard let attributes = run["attributes"] as? [String: Any] else { continue }
    for name in ["AXForegroundColor", "AXBackgroundColor", "AXUnderlineColor"] {
      if let color = attributes[name] as? [String: Any], color["kind"] as? String == "CGColor" {
        hasColor = true
      }
    }
    if attributes["AXFont"] is [String: Any] { hasFontDictionary = true }
    if let candidate = attributes["AXLink"] as? [String: Any] { link = candidate }
  }
  let linkRole = link?["AXRole"] as? String
  let linkURL: String?
  if let url = link?["AXURL"] as? [String: Any] {
    linkURL = url["value"] as? String
  } else {
    linkURL = link?["AXURL"] as? String
  }
  let actions = link?["actions"] as? [String] ?? []
  let attributedText = attributed["string"] as? String
  let attributedLength = attributed["utf16_length"] as? Int
  let valueText = value["text"] as? String
  let styleError = styleRanges.contains { $0["error"] != nil }
  return [
    "ax_value_read_only": value["settable"] as? Bool == false,
    "plain_matches_attributed": plain == attributedText,
    "utf16_length_matches": attributedLength == (plain as NSString?)?.length
      && attributedLength == (valueText as NSString?)?.length,
    "style_range_for_each_queried_utf16_index": !styleError,
    "cgcolor_attributes_returned": hasColor,
    "font_dictionary_returned": hasFontDictionary,
    "link_ax_element_returned": link?["kind"] as? String == "AXUIElement",
    "link_role_returned": linkRole == "AXLink",
    "link_url_returned": linkURL == "https://example.test/ax",
    "link_press_action_returned": actions.contains(kAXPressAction as String),
    "link_geometry_returned": link?["frame"] != nil,
  ]
}

private func writeReport(_ report: [String: Any], path: String?) throws {
  let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
  if let path { try data.write(to: URL(fileURLWithPath: path), options: .atomic) }
  else { print(String(decoding: data, as: UTF8.self)) }
}

private func trustedWithoutPrompt() -> Bool {
  let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
  return AXIsProcessTrustedWithOptions([promptKey: false] as CFDictionary)
}

private let parsedArguments = try? Arguments()
do {
  let arguments = try parsedArguments ?? Arguments()
  var report: [String: Any] = [
    "probe": "external-accessibility-attributed", "pid": Int(arguments.pid),
    "identifier": arguments.identifier, "permission_prompt_requested": false,
  ]
  guard trustedWithoutPrompt() else {
    report["passed"] = false
    report["error"] = "AXIsProcessTrustedWithOptions(prompt: false) returned false; no accessibility query attempted."
    try writeReport(report, path: arguments.reportPath)
    exit(EXIT_FAILURE)
  }
  report["accessibility_trusted"] = true
  let pane = try findPane(AXUIElementCreateApplication(arguments.pid), identifier: arguments.identifier)
  report["pane"] = describeElement(pane)
  let value = try readOnlyValue(pane)
  report["value"] = value
  let text = value["text"] as! String
  let rangeQuery = try queryRange(pane, value: text)
  let rangeStyles = styleRanges(pane, length: (text as NSString).length)
  let checks = assertions(value: value, rangeQuery: rangeQuery, styleRanges: rangeStyles)
  report["range_query"] = rangeQuery
  report["style_ranges"] = rangeStyles
  report["style_range_index_query_count"] = min((text as NSString).length, 512)
  report["assertions"] = checks
  report["passed"] = checks.values.allSatisfy { $0 }
  try writeReport(report, path: arguments.reportPath)
  exit((report["passed"] as? Bool) == true ? EXIT_SUCCESS : EXIT_FAILURE)
} catch {
  let report: [String: Any] = [
    "probe": "external-accessibility-attributed", "passed": false,
    "error": String(describing: error), "permission_prompt_requested": false,
  ]
  do { try writeReport(report, path: parsedArguments?.reportPath) }
  catch { fputs("AccessibilityProbe reporting failed: \(error)\n", stderr) }
  exit(EXIT_FAILURE)
}
