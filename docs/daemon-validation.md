# Signed helper validation

The helper is optional, telemetry-only, and intentionally unusable from an
unsigned build. These tests require a distribution-signed app on an owner
controlled machine; do not weaken the peer validator to make local testing
easier.

## Automated coverage

Anonymous-XPC tests cover handshake version negotiation, streaming,
invalidation cleanup, and explicit peer-policy rejection without root. They use
`DaemonPeerValidator.currentProcessForTesting`; production uses the strict
same-team/active-console policy.

## Owner-only hardware steps

1. Build the final signed candidate and verify both executables:

   ```bash
   codesign --verify --deep --strict --verbose=2 /Applications/Loupe.app
   codesign --verify --strict --verbose=2 \
     /Applications/Loupe.app/Contents/MacOS/loupedaemon
   ```

2. Confirm the helper is at `Contents/MacOS/loupedaemon`; the plist is at
   `Contents/Library/LaunchDaemons/ai.squint.loupe.daemon.plist`; its filename,
   `Label`, Mach service, and source constants agree.
3. From **Telemetry**, click **Install**, approve under System Settings → Login
   Items, and refresh. The handshake must show version 0.2.0 and protocol v2;
   samples must advance.
4. Run a recording. GPU/power fields should appear when IOReport resolves;
   absent channels must remain absent, never zero-filled.
5. Force-quit the app while streaming. The helper must stop that connection's
   sampler. Relaunch and verify a fresh connection succeeds.
6. Connect a separately signed/ad-hoc test client and a client under another
   user. Both must be rejected; no handshake or samples may be delivered.
7. Send an unsupported protocol version from an allowed test client. The reply
   must be empty and `startSampleStream` must do nothing.
8. Reboot, relaunch, refresh, and verify approval survives and streaming resumes.
9. Stall the app-side consumer long enough to force bounded helper and receiver
   backpressure, then stop normally. Confirm the session reports a nonzero
   telemetry acquisition count and that a terminal summary closes the exact
   window. Kill the helper before its summary and confirm the UI/export says
   unknown with any observed sequence-gap lower bound, never zero.
10. Stop, quit, and relaunch. Confirm History and JSON/CSV preserve the same
    acquisition exact/lower-bound values while replay parser drops remain a
    separate field.
11. Uninstall in the app; confirm the service disappears from `launchctl`.
12. Repeat on the supported Apple Silicon matrix. Record chip, macOS build,
    resolved IOReport channels, result, and logs in the release evidence.

No step in this document has been completed merely because the source exists.
The release owner must attach actual results to the candidate.
