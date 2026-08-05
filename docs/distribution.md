# Distributing Loupe (direct download, no App Store)

Loupe ships as a DMG users download from any website and drag into
`/Applications`. Gatekeeper requires the app to be **Developer ID signed and
notarized** — without that, downloads are blocked on every machine but yours.

## One-time setup

1. Join the [Apple Developer Program](https://developer.apple.com/programs/)
   ($99/year) with the team whose ID lives in `Local.xcconfig`.
2. In Xcode (Settings → Accounts → Manage Certificates) create a
   **Developer ID Application** certificate.
3. Store notarization credentials once (uses an App Store Connect API key or
   app-specific password):

   ```bash
   xcrun notarytool store-credentials loupe-notary --apple-id you@example.com --team-id ABCDE12345
   ```

## Cutting a release

```bash
LOUPE_SIGN_IDENTITY="Developer ID Application: Your Name (ABCDE12345)" \
LOUPE_NOTARY_PROFILE=loupe-notary \
make dist
```

That produces `dist/Loupe-<version>.dmg` — signed, notarized, stapled, and
ready to upload to any static host (your site, GitHub Releases, a CDN).
`make dist` without the env vars builds an unsigned DMG for local testing.

## What users experience

1. Download `Loupe-x.y.z.dmg`, open it, drag Loupe to Applications.
2. First launch: standard "downloaded from the internet" confirmation
   (stapled notarization means no scary warnings, works offline).
3. Installing the privileged daemon prompts once in
   System Settings → Login Items — that flow is native `SMAppService` and
   works exactly the same for Developer ID apps as for App Store ones.

**Run from `/Applications`.** `SMAppService` refuses daemons registered from
translocated locations (e.g. running the app directly out of the DMG or
`~/Downloads`).

## Versioning

Bump **both** `MARKETING_VERSION` in `project.yml` and `Loupe.version` in
`Sources/LoupeCore/Loupe.swift` (the version the daemon handshake and UI
report). `make dist` refuses to build when they disagree; the DMG filename
follows the version.
