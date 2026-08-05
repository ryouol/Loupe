# Daemon manual validation (signed hardware run)

What the M0.6 test suite cannot cover — real `SMAppService` registration,
launchd, and reboot survival — is validated by hand with a signed build.
Everything else (XPC round trip, streaming, the degraded path) is covered by
`swift test` without root.

## Prerequisites

1. Set your Team ID in `Local.xcconfig`: `DEVELOPMENT_TEAM = ABCDE12345`.
2. Remove the `CODE_SIGNING_ALLOWED=NO` override for this run — build via
   Xcode or `xcodebuild build -scheme Loupe -destination 'platform=macOS'`
   with signing enabled so the embedded daemon gets signed too (the embed
   script signs it with the app's identity automatically).

## Steps

1. **Bundle layout.** After building, verify inside `Loupe.app`:
   `Contents/MacOS/loupedaemon` exists and is signed; the plist is at
   `Contents/Library/LaunchDaemons/ai.squint.loupe.daemon.plist`; its
   `Label` equals the filename (minus `.plist`).
2. **Register.** Launch the app (from `/Applications` — SMAppService is
   picky about translocated paths), open **Daemon** in the sidebar, click
   **Install…**. Expected status: *Waiting for approval*; System
   Settings → Login Items opens automatically.
3. **Approve** the daemon under "Allow in the Background", then click
   **Refresh** in the app — status must flip to *Running* and streaming
   starts on its own (no separate start control exists).
4. **Stream.** Expected in the Live Telemetry section: a daemon line
   (version + protocol + pid) from the handshake, the samples counter
   advancing at ~10 Hz, thermal/memory values moving.
   `sudo launchctl list | grep ai.squint.loupe` shows the daemon; its
   stderr appears in `log stream --process loupedaemon`.
5. **Reboot survival.** Reboot, launch the app, open Daemon, click
   Refresh: status must still be *Running* and samples must flow without
   reinstalling.
6. **Client-death cleanup.** While streaming, force-quit the app (⌥⌘⎋).
   In `log stream --process loupedaemon`, sampling must stop within a
   second or two — the connection's invalidation handler shuts the
   broadcaster down; a root daemon must not keep sampling for a dead
   client.
7. **Denial path.** Uninstall, reinstall, but this time **decline** in
   System Settings. Expected: app keeps running, shows the observed-mode
   banner, Install remains available, no crash, no blocked launch.
8. **Uninstall.** Click **Uninstall**; status returns to *Not installed*
   and `launchctl list` no longer shows the label.

## Known limits at M0.6

- The daemon streams unprivileged system-wide samples only; per-process and
  GPU/power channels arrive with M1.1/M1.2 (IOReport needs the root context
  this daemon now provides).
- The listener does not yet verify the peer's code signature — gated on the
  Team ID, tracked as a TODO in `DaemonListenerDelegate` for M1.
