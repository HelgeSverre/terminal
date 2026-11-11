# SidePulse Pro (experimental)

Enable **Settings → SidePulse Pro → Enable SidePulse Pro**, click **Apply**, then reopen Settings and click **Test lights**. The three-second green preview restores live status automatically. The setting defaults to off. Settings reports connection and write errors; a disconnected device never blocks terminal use.

The terminal discovers mounted `/Volumes/SidePulse`, `/Volumes/SidePulsePro`, and numbered variants automatically. Connect one Pro at a time. Renamed volumes and SidePulse Dot are not supported by this first version. The integration requires ordinary write access to the existing `LEDS.LED` file. No vendor software, shell command installation, raw disk access, or administrator privileges are needed.

| Event | LEDs |
| --- | --- |
| Shell command running | Cyan roll |
| Successful command | Green for six seconds |
| Failed command | Red pulse for six seconds |
| Terminal bell (BEL) | Amber pulse for six seconds |
| Idle | Off |

The bundled interactive zsh integration emits OSC 133 command boundaries and exit status. Other shells need to emit `OSC 133;C` at command start and `OSC 133;D;<exit status>` at completion. Missing/invalid exit status means idle, never inferred success. Output alone does not indicate that a command is running. Password prompts and agent approval requests cannot be inferred reliably; applications can ring the terminal bell for attention. Direct `--execute` processes without OSC 133 have bell feedback only.

Across windows, tabs, and split panes, failure takes priority over bell, running, success, and idle. A completion in one pane cannot hide another running command. Transient alerts expire; a bell during a command restores its running indication afterwards. Closing or finishing a session removes its activity. Rendering checks state once a second, so very short commands may go straight to their completion color. A command must return to its shell before its exit status is known.

## Device behavior and coexistence

A utility queue serializes device writes outside the PTY/parser and UI threads. Programs are fixed and validated before opening the file (512 UTF-8 bytes / 20 physical lines). The writer opens the existing regular file without creating or following a symlink, truncates in place, writes completely, and best-effort syncs. It never uses atomic replacement, writes `INIT.LED`, installs firmware, or changes startup animations.

Unchanged programs are deduplicated. Once a minute the current program is resent to perform real device I/O and keep older MacBook SD readers active. This restarts the animation once per minute; physical testing must confirm keep-alive and caching behavior. Detection and writing stop when disabled. Disable and normal quit make a best-effort `off` write only to the still-mounted, unambiguous device this process controlled. Force quit cannot run cleanup.

The official SidePulse app/service and this terminal both control the same LEDs: the last writer wins. Choose one controller while testing; this integration does not change the vendor's hooks, service, or settings. Two Terminal instances can also compete. A disconnected or read-only device is retried at the next bounded refresh; no alternate transport is attempted. Use the official tool for firmware-1.1 READ2ME support when storage writes are restricted.

The Pro can disappear after lock or sleep. Re-detection resumes when it remounts. The vendor's optional Eject Prevention helper is separate from this feature; the terminal does not keep the Mac awake or change sleep/ejection policy.

## Validation before merging

Run `just unit-test --filter SidePulseTests` for real parser chunking, initial prompt suppression, OSC terminators versus bell, command exit handling, multi-pane priorities, alert expiry, preview restoration, deduplication, reconnect, ambiguity, write retry, disable, and actual file writer checks. Run `just settings-window-test` to construct the real Settings window and check control bounds. Run the preferences test group for persistence and zsh exit-status hooks. These tests use temporary files and an injected device list; they never write to hardware.

The PR remains a draft until these physical checks pass:

- Enable with no Pro; insert it; send the test pattern; confirm automatic restoration and brightness.
- In fresh zsh sessions run `sleep 5`, `true`, `false`, and `printf '\a'`. Confirm cyan/green/red/amber without firmware parser-error flashes.
- Run commands concurrently in different panes/windows; fail one while another runs; close the running pane and verify expiry/cleanup.
- Disable, re-enable during a running command, unplug/replug, and quit normally. Confirm no stale activity or writes while disabled.
- Leave it idle for over three minutes, then lock/unlock and sleep/wake with and without the vendor helper. Confirm keep-alive and re-detection.
- Check read-only errors and two mounted Pros. Neither should crash or arbitrarily choose a device.
- Test coexistence with the official companion app and with two terminal instances; choose the desired controller.

## Sources

Research was performed on 2026-11-09 against the [setup guide](https://sidepulse.io/setup), its linked CLI repository, protocol and firmware documentation, and the corresponding source at commit `ffb1d3c2f3eed3b7e80e32d7876a7e1d67bd5dfb`.

- [Setup and troubleshooting](https://sidepulse.io/setup): mounted drive workflow, sleep/lock caveats, optional helpers.
- [CLI README](https://github.com/inteliwear/sidepulse/blob/ffb1d3c2f3eed3b7e80e32d7876a7e1d67bd5dfb/README.md): detection, multi-device ambiguity, agent states, background service, battery/phone capabilities and read-only transports.
- [LED language](https://github.com/inteliwear/sidepulse/blob/ffb1d3c2f3eed3b7e80e32d7876a7e1d67bd5dfb/LEDS_FORMAT.md): limits, brightness, pulse/roll behavior, persistent `INIT.LED`, and minute keep-alive recommendation.
- [Vendor writer](https://github.com/inteliwear/sidepulse/blob/ffb1d3c2f3eed3b7e80e32d7876a7e1d67bd5dfb/src/sidepulse/device_writer.py): truncate/write/flush/sync, serialized I/O, denied-open fallback policy.
- [Firmware notes](https://github.com/inteliwear/sidepulse/blob/ffb1d3c2f3eed3b7e80e32d7876a7e1d67bd5dfb/firmware/README.md) and [read-only implementation](https://github.com/inteliwear/sidepulse/blob/ffb1d3c2f3eed3b7e80e32d7876a7e1d67bd5dfb/src/sidepulse/readonly_control.py): READ2ME is deliberately deferred.
- [Keep-awake implementation](https://github.com/inteliwear/sidepulse/blob/ffb1d3c2f3eed3b7e80e32d7876a7e1d67bd5dfb/src/sidepulse/keep_awake.py): vendor uses an uncached status read; this draft instead resends the live program for compatibility with older devices.
- [Animation library](https://github.com/inteliwear/sidepulse/tree/ffb1d3c2f3eed3b7e80e32d7876a7e1d67bd5dfb/src/sidepulse/resources/animations): baseline programs; this integration uses its own compact low-brightness palette and red for shell failure.

Phone push, Dot, battery display, raw-disk recovery, custom animation editing, agent-specific hooks, firmware updates and the iOS/Android apps were reviewed as adjacent capabilities and are outside this Pro terminal integration.
