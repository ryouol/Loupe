# Distribution pipeline

Loupe is intended for direct distribution as an Apple Silicon DMG. The
repository does not contain a Developer ID identity, Team ID, notary profile,
or proof that notarization has succeeded.

## Artifact names are trust labels

| Output | Meaning | Customer release? |
|---|---|---|
| `Loupe-x.y.z-unsigned.dmg` | CI/local package mechanics only; helper disabled; Gatekeeper rejection expected | No |
| `Loupe-x.y.z-signed-unnotarized.dmg` | Signature validation only | No |
| `Loupe-x.y.z.dmg` | Script completed signing, notarization, stapling, and Gatekeeper assessment | Candidate, pending owner checklist |

`scripts/make-dist.sh` will not give a non-notarized image the final filename.

## Credential-free checks

```bash
make verify
```

This builds Swift targets, lints, checks the diff, runs Python tests, verifies
and vulnerability-scans both dependency locks, validates the bundled sample
and daemon plist, then runs Swift XCTest plus the Xcode app build when full
Xcode is selected. A Command Line Tools-only host can run the remaining paths
with
`LOUPE_ALLOW_TOOLCHAIN_LIMITED_VERIFY=1`, but that result is explicitly
insufficient for a signed release.

CI runs the complete gate on macOS and then builds the unsigned smoke image.
The launch-readiness snapshot records the exact local toolchain limitation:
parse/build checks from Command Line Tools are useful evidence, but they are
not substitutes for the full-Xcode XCTest and app-target gates.

## Owner-only signed candidate

Prerequisites:

1. Apple Developer Program membership and a valid Developer ID Application
   certificate.
2. Full Xcode selected via `xcode-select`.
3. A keychain notary profile created outside the repository.
4. `Local.xcconfig` populated locally; never commit Team IDs or credentials.
5. Counsel-approved license, privacy notice, terms, and third-party inventory.

```bash
LOUPE_SIGN_IDENTITY="Developer ID Application: …" \
LOUPE_NOTARY_PROFILE="owner-notary-profile" \
make dist
```

The script verifies version parity and always reruns the full release gate for
any signed artifact; the CI-attestation shortcut applies only to unsigned
smoke packaging. It then checks arm64 binaries, bundled sample/legal resources,
matching Developer ID app/helper Team IDs, and strict signatures. It then
notarizes, staples, and Gatekeeper-assesses the app before preserving it in the
DMG; the DMG is separately notarized, stapled, assessed, verified, and hashed.

## Manual release checklist

- Run the signed helper tests in `daemon-validation.md` on each supported chip
  family and every macOS major/security update the offer claims to support.
- Mount the candidate on a clean non-developer Mac; install from the DMG and
  repeat sample, real recording, history, export, quit/relaunch, and uninstall.
- Confirm the app displays the approved legal text and support/security contact.
- Compare the published SHA-256 to the generated sidecar.
- Archive CI run URL, source commit, dependency locks, notary log, signatures,
  test results, and the exact uploaded DMG.
- For any benchmark claim, archive the exact model artifact and independently
  verify its SHA-256 plus runtime version and model revision; the benchmark CLI
  requires those values but cannot prove operator-supplied assertions by itself.
- Do not publish if any helper/signing/notary/Gatekeeper gate is skipped.
