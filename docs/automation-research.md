# Accessibility and automation research

Scope: macOS 15+ native host, bundle `no.helgesverre.terminal`. This is a
recommendation for a future automation surface, not an implementation plan that
changes terminal editing semantics.

Research baseline: `2be6503`. The stable window/pane identifiers and settings
control identifiers described below have since been implemented. Pane/window
identifiers include an immutable UUID. AppleScript commands and the scripting
object model remain pending; this document does not claim they are available.

## What is already truthful

`TerminalCanvasView` is already an accessibility element with the text-area
role and label “Terminal pane”. It exposes character count, selected and
visible ranges, text/range/line lookup, hit-tested ranges, range frames, and
coalesced value/selection notifications. `AccessibilityProjection` maps the
*currently displayed immutable grid* to UTF-16 and caps it at 262,144 code
units. Crucially, `Canvas.swift` refuses `setAccessibilityValue:` and
`setAccessibilitySelectedText:`. That agrees with AppKit’s model: expose
read-only attributes as getter-only, and only offer setters for values an
assistive client may actually change ([`NSAccessibilityProtocol`](https://developer.apple.com/documentation/appkit/nsaccessibilityprotocol)).

Keep this distinction. A pane’s screen projection is readable/selectable
output, not an editable transcript or a command-input document. Do not make
the scrollback editable merely so an automation client can write `AXValue`.
Text clients can obtain parameterized string/range/line/bounds information
without mutation ([Accessibility parameterized attributes](https://developer.apple.com/documentation/applicationservices/carbon_accessibility/parameterized_attributes)).
The current range methods are a good basis for `AXStringForRange`,
`AXRangeForIndex`, `AXRangeForLine`, `AXLineForIndex`, and
`AXBoundsForRange`; return only ranges the projection can honestly represent,
including its UTF-16 coordinate system and truncation boundary.

`AXSelectedTextRange` is a valid selection/navigation affordance, but it must
continue to alter only `GridSelection`, never shell input. Advertise or handle
an AX action only where it represents a real UI operation; AX clients discover
supported actions and attributes rather than being entitled to arbitrary
control ([`AXUIElementCopyActionNames`](https://developer.apple.com/documentation/applicationservices/1459729-axuielementcopyactionnames),
[`AXUIElementIsAttributeSettable`](https://developer.apple.com/documentation/applicationservices/1462338-axuielementisattributesettable)).
Keep `.valueChanged` and `.selectedTextChanged`; add focus/layout notifications
only when those states actually change ([`NSAccessibility.Notification`](https://developer.apple.com/documentation/appkit/nsaccessibility-swift.struct/notification)).

## Strong, stable AX names

Labels remain concise user-facing prose; identifiers are stable, unlocalized
machine names. Apple describes `accessibilityIdentifier` as a unique identity
often used for automated testing ([documentation](https://developer.apple.com/documentation/appkit/nsaccessibility-c.protocol/accessibilityidentifier)).
Set identifiers explicitly instead of deriving them from titles, row positions,
or terminal contents:

| Element | Current label/title | Recommended identifier |
| --- | --- | --- |
| `TerminalCanvasView` | Terminal pane | `no.helgesverre.terminal.pane` |
| Settings window | Settings | `no.helgesverre.terminal.settings` |
| Starting-directory field | Starting directory | `no.helgesverre.terminal.settings.starting-directory` |
| Choose-directory button | Choose… | `no.helgesverre.terminal.settings.choose-directory` |
| Font-size field | Font size in points | `no.helgesverre.terminal.settings.font-size` |
| Scrollback field | Scrollback rows | `no.helgesverre.terminal.settings.scrollback-rows` |
| Follow-tail checkbox | Scroll to bottom when typing | `no.helgesverre.terminal.settings.follow-tail-on-input` |
| Option checkbox | Option key sends Escape | `no.helgesverre.terminal.settings.option-sends-escape` |
| Validation text | Settings validation | `no.helgesverre.terminal.settings.validation` |
| Apply / Cancel | Apply / Cancel | `no.helgesverre.terminal.settings.apply` / `.cancel` |

Set these where controls are constructed in `Settings.swift` and the pane is
constructed in `Canvas.swift`. Standard `NSTextField`, `NSButton`, and
`NSWindow` behavior should carry the appropriate editable/press/toggle actions;
do not replace it with synthetic AX actions. If multiple panes need a distinct
identifier, add an immutable app-owned pane UUID (not a split index or shell
title), retain it for that pane’s lifetime, and expose it separately from the
common base identifier. The main automation selector should otherwise be the
focused pane/window.

The settings labels are already unusually good. Complete the contract by
labeling/identifying the unlabelled buttons and toggles, and expose validation
text only when nonempty (with an appropriate value/layout notification). Make
the disabled Apply state observable through the normal button enabled state.

## Terminal input: a deliberate command, not AX value setting

`Canvas.swift` routes committed text through `NSTextInputClient` to the PTY
and deliberately keeps it separate from the read projection. For reliable
agent-desktop/AppleScript automation, add an explicit, security-reviewed
application command such as `send text <text> [to pane]` rather than posting
keystrokes or assigning terminal `AXValue`. It should use the same ordered
input path as committed text, require an explicit target (default: focused
pane), reject closed/busy sessions consistently, and return a result/error. It
must not pretend that reading output is editing input.

This makes scripting direct rather than macro-like UI scripting, which Apple
recommends as the complement to a scriptable object model
([Cocoa scripting overview](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/AppArchitecture/Concepts/Scripting.html)). It
also preserves IME/key/mouse semantics in `Canvas.swift`: automated text is a
text-only commit, not a fabricated hardware event. Keep ordinary menu actions
(copy, paste, clear, font size, split) available through their real menu/AX
actions, but do not grant a generic “execute command” AX action.

## AppleScript/SDEF boundary

There is currently no `.sdef`, `OSAScriptingDefinition`,
`NSAppleScriptEnabled`, or scriptable object model in `Info.plist`; `main.swift`
owns windows/panes while `Preferences.swift` is a value type. If AppleScript is
needed, add a small model layer rather than expose `TerminalCanvasView`,
`Session`, or Rust objects:

```
application -> terminal windows -> terminal panes
                           \-> preferences (explicit, limited properties)
commands: send text, show settings, optionally set validated preference
```

Put `Terminal.sdef` in the app Resources directory and point
`OSAScriptingDefinition` at its basename; Apple documents that bundle contract
([Scripting Definition Files](https://developer.apple.com/library/archive/documentation/AppleScript/Conceptual/AppleScriptLangGuide/conceptual/ASLR_script_objects.html)).
Declare the scripting capability in the app Info.plist with
`NSAppleScriptEnabled=YES` ([Cocoa Info.plist keys](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/CocoaKeys.html)).
Use four-character codes that are treated as API: never recycle one after a
release.

Implement scriptable records as `NSObject` subclasses with public
`@objc dynamic` KVC properties/relationships, not Swift structs or private
view fields. Cocoa scripting resolves scriptable object graphs through KVC and
object specifiers ([`NSScriptObjectSpecifier`](https://developer.apple.com/documentation/foundation/nsscriptobjectspecifier)); Swift objects used by
Objective-C/KVC dynamics need `NSObject`, Objective-C exposure, and `dynamic`
dispatch ([Apple’s Swift/KVC example](https://developer.apple.com/documentation/appkit/developing-a-document-based-app)).
Give window/pane records canonical object specifiers and stable IDs so a script
does not accidentally retarget after tab/split reshuffling.

Implement domain commands with `NSScriptCommand` subclasses when the default
KVC behavior is insufficient: validate arguments/targets on the main thread,
then call the existing owned-session API and return meaningful Apple-event
errors. Cocoa turns incoming Apple events into an `NSScriptCommand` and invokes
its handler/default implementation ([`NSScriptCommand`](https://developer.apple.com/documentation/foundation/nsscriptcommand)). Do not expose raw
`TerminalPreferences` as writable KVC fields; route writes through the existing
`TerminalPreferences.edited` validation, save, and `applyPreferences()` path.

## Tests and consent boundaries

Test AX externally, because direct Swift method calls in `NativeSmokeTest` do
not prove the exported AX tree. A dedicated test bundle/fixture should use a
distinct bundle identifier and isolated defaults/home/session, launch only a
disposable `--execute` child, capture role/label/identifier/action/settable
attribute snapshots, and assert the read/range API and the *absence* of writable
terminal `AXValue`. `AXUIElement` clients can enumerate attributes/actions and
read values, but must tolerate unsupported attributes and AX messaging failures
([`AXUIElement.h`](https://developer.apple.com/documentation/applicationservices/axuielement_h)).

For UI tests, launch the fixture by its test target URL/bundle, pass fixture
arguments, and terminate it; `XCUIApplication` supports an app proxy plus
`launchArguments` ([`XCUIApplication`](https://developer.apple.com/documentation/xcuiautomation/xcuiapplication),
[`launchArguments`](https://developer.apple.com/documentation/xcuiautomation/xcuiapplication/launcharguments)). Never use the user’s installed/live
`no.helgesverre.terminal`, its defaults, or their interactive shell.

Accessibility consent is for the *controlling client* (agent-desktop/test
runner), not for this target merely exposing an accessibility hierarchy. Check
the client with `AXIsProcessTrustedWithOptions`, handle denial as a skipped or
explicitly gated integration test, and never make a test mutate global TCC
state ([API documentation](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions)).
Inbound AppleScript is different from Terminal sending Apple events. Only the
latter needs an `NSAppleEventsUsageDescription` prompt; sandboxed/hardened
senders may additionally need the Apple Events entitlement
([usage-description key](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription),
[entitlement](https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.security.automation.apple-events)).
App Sandbox also restricts accessibility-assistive APIs and arbitrary outbound
Apple events ([sandbox restrictions](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)); do not add a sandbox or
entitlement as an automation workaround without a separate distribution review.
