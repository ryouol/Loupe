# Privacy notice draft

Effective date: not yet approved for release.

Loupe is designed to operate locally on your Mac. The current application has
no account system, analytics SDK, advertising SDK, crash uploader, telemetry
endpoint, or automatic cloud-sync path.

## Data Loupe processes

- runtime metadata such as model/runtime identifiers, token counts, request
  timing, provenance-typed KV or allocator-memory observations, and adapter
  errors;
- system telemetry such as memory, swap, thermal state, GPU/power when
  available, and CPU/RSS for the observed process;
- session names you enter;
- benchmark specifications, including prompt-corpus text when you explicitly
  run the benchmark CLI.

The built-in adapters have no prompt or generated-text event fields and
sanitize generation failures. Session names, third-party adapter error strings,
benchmark inputs, model identifiers, and timing can still be sensitive. A
custom adapter can put inappropriate data in free-form metadata, so inspect
files before sharing them.

## Storage and retention

Sessions are stored below `~/Library/Application Support/Loupe` with owner-only
permissions. Completed sessions remain until you delete them from History or
remove their files. Imported files remain wherever you selected them. Export
occurs only when you choose an export destination.

## Network behavior

The Loupe app and helper do not upload sessions. The llama.cpp adapter refuses
non-loopback servers. Optional third-party model/runtime tools can access the
network independently. For example, mlx-lm may download a model under its own
terms and configuration.

## Sharing

Loupe does not sell or share session data. If you manually send an evidence
file, benchmark report, or portable session bundle to another person or service, that
recipient's practices apply.

## Contact and release gate

A real privacy/support contact and jurisdiction-specific disclosures must be
added before commercial distribution. The repository owner must have counsel
approve this draft; it is not legal advice or a completed privacy policy.
