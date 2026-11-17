# Native input and accessibility validation

This is the pending manual qualification recipe for inventory U04/U05 and
V02/V03. Unit tests exercise composition storage, geometry and bounded history
pages. They do not establish physical keyboard behavior, candidate-window
placement, VoiceOver speech, or usability. No physical-input or speech run has
been recorded for this change yet.

## Test identity and setup

Record the tested commit, macOS build, hardware, keyboard model/layout, input
source names and versions, shell/client versions, display scale, and language
settings. Build through the repository's normal bundle workflow after obtaining
the machine's single build slot. Copy the resulting bundle before testing;
record its path and the executable SHA-256. Launch that copy with a fresh test
window. Do not replace or automate Helge's installed terminal.

Use a plain shell prompt first, followed by `cat`, a current editor, and tmux.
Keep actual sent text visible in the test client, and capture the candidate
window and composition as screenshots or a screen recording. Record each step
as pass, failure with observed behavior, or unavailable input source/hardware.
Switching input sources and enabling VoiceOver require the human tester; do not
toggle the user's system accessibility settings unattended.

## V02: physical input and composition

1. With ABC and a non-US physical layout, type letters, punctuation, Shift,
   Control combinations, and a dead-key sequence such as Option-E then E.
   Verify the committed text once, without leaking the dead key to the client.
   Repeat with each configured left/right Option policy, keeping the opposite
   Option side pressed in a separate case. Record escape-producing and
   input-source-producing behavior separately.
2. With Japanese Romaji, enter `nihongonyuuryokutesuto`, convert with Space,
   move between conversion clauses, change a candidate, and commit with Return.
   Verify clause emphasis, selected-clause/caret location, and the exact
   committed text. Backspace and Escape must affect pending composition without
   committing it unexpectedly or deleting arbitrary shell output.
3. With Simplified Chinese Pinyin, enter `zhongwenshurufaceshi`, select candidates
   by number and by arrow/Return, then repeat with a composition longer than
   20 terminal cells near the right edge and on the bottom row. The candidate
   window must follow the selected clause rather than the original cursor.
4. With Korean 2-Set, enter and revise multiple syllables, then commit and
   backspace. Include adjacent Latin text, combining accents and emoji. Verify
   each committed character once and correct wide-cell placement.
5. During a long pending composition, move the selection/caret back toward the
   beginning and end, click within its displayed text, and inspect candidate
   placement. The bounded display window must follow the caret while the input
   source retains the full composition. Hit mapping must use UTF-16 boundaries
   without splitting a surrogate or composed character.
6. Repeat at 1x and 2x scale and after changing font size. Resize the pane,
   switch panes/windows and input sources, and scroll while composing. A
   geometry/screen change or loss of focus may cancel pending composition; it
   must never send it to the newly focused pane or commit it as a side effect.
   Verify that subsequent typing and candidate coordinates recover normally.
7. Repeat the conversion, cancellation, dead-key and Option checks inside tmux
   and the chosen editor, recording negotiated keyboard mode and client
   versions. A synthetic NSEvent test does not substitute for this step.

The input client's editable text storage is only the pending composition. A
replacement request outside that storage is rejected; it does not promise
reconversion or arbitrary editing of text already sent to a shell or program.
The renderer shows up to eight terminal rows of preedit around the selected
caret, using engine Unicode widths and preserving complete UTF-16 document
offsets. Pending storage is limited to 65,536 UTF-16 units.

## V03: VoiceOver speech and history navigation

1. Have the tester enable VoiceOver. Focus the test terminal pane and use
   ordinary text-area navigation to read a prompt, mixed-width text, blank
   lines, and wrapped output. Verify speech order, line boundaries, cursor and
   selection reporting. Check that live output announcements remain usable
   while the terminal streams output, rather than repeatedly interrupting
   navigation.
2. Produce at least 200 numbered lines. Invoke the pane's **Read output
   history** custom action from VoiceOver's Actions menu. Navigate to the
   **Terminal output history** text area and read several lines. Check that
   the ready announcement leads to a discoverable reader without unexpected
   focus changes. The page must remain readable while new output arrives.
3. In that reader invoke **Read older output**, **Read newer output**, and
   **Read latest output**. Read across page boundaries and verify monotonically
   ordered numbered lines, no skipped/duplicated boundary row, and disabled
   older/newer actions at the ends. Pages are bounded to 64 physical rows,
   32,768 cells and 65,536 UTF-16 units; wide terminals can return fewer rows.
   A page containing a clipped row identifies that condition in its label.
4. While retaining a history page, generate enough output to evict its anchor,
   clear scrollback, switch alternate screens, or reset the terminal. Request
   an adjacent page. Verify the expired-position announcement, then recover
   with **Read latest output**. Previously fetched immutable text must remain
   readable; no UI query may hang waiting on the terminal owner.
5. Select and read text within the history reader. Verify this is a read-only
   browsing selection and does not send text, change the terminal's selection,
   move its viewport, or alter the running shell. Return to the pane and check
   normal keyboard input, select/copy, find, next/previous match and link
   navigation with speech enabled.
6. Repeat in a screen editor and with multiple panes, then close a pane while
   a history read is pending. Verify responsive focus/navigation and cancellation
   without stale announcements from the closed pane. Record macOS coverage
   separately from UIKit/VoiceOver coverage on other platforms.

## Evidence and automated checks

After integration, run the `NativeTextTests` and `HistoryPageTests` suites, plus
existing `SnapshotBridgeTests`, `VisibleLinkProjectionTests`, session/input
regressions, and the external accessibility smoke check in the coordinated
test slot. Run the repository's full required gates at the integrated commit.

Retain a compact dated report under `reports/`, following `reports/README.md`,
with commands, actual results, commit, frozen-bundle hash and selected media.
List unavailable keyboard/input sources and any untested workflow explicitly.
The implementation remains unqualified for V02/V03 until the human runs and
records these physical-input and actual-speech workflows.

The native contract follows Apple's [NSTextInputClient reference](https://developer.apple.com/documentation/appkit/nstextinputclient),
including [selectedRange](https://developer.apple.com/documentation/appkit/nstextinputclient/selectedrange())
and [unmarkText](https://developer.apple.com/documentation/appkit/nstextinputclient/unmarktext()).
Composition mouse gestures are offered to [NSTextInputContext.handleEvent](https://developer.apple.com/documentation/appkit/nstextinputcontext/handleevent(_:))
before terminal selection or mouse reporting.
