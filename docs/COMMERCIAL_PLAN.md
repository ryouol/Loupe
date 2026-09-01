# Commercial and launch plan

This is a validation plan. Checkout, license delivery, signing, and customer
demand are not yet complete.

## One offer

**Loupe early access: US$149 one time.** The license covers one named developer
on that person's Macs and includes 12 months of updates. The product includes
local session history, evidence-backed findings, MLX and llama.cpp adapters,
strict benchmark comparison, and JSON/CSV evidence export.

There are no tiers, subscription, cloud account, or usage allowance. The
bundled sample is the free evaluation path and has zero variable compute cost.

The launch CTA is **Buy Loupe for US$149**. Until the distribution gates pass,
use **Open the sample session** in private demos and do not publish a purchase
CTA.

## Payment and entitlement boundary

Use a hosted checkout and seller-managed secure download rather than adding a
network SDK or license server to the app. The receipt plus written license
grant is the entitlement for early access. Loupe itself remains fully offline
and contains no payment secret.

Before enabling live checkout, the owner must:

1. choose a provider that supports one-time digital-software sales and the
   owner's tax/legal requirements;
2. configure a US$149 product in test mode;
3. verify successful, cancelled, failed, refunded, and duplicate purchase
   behavior;
4. ensure only the signed and notarized DMG is delivered;
5. document download expiry, replacement access, refunds, and support;
6. have counsel approve the license and customer-facing terms.

No checkout or entitlement is implemented in this repository because there is
no approved seller identity, provider account, domain, or signed artifact. A
fake buy button would weaken the product and misstate launch readiness.

## Economics and validation threshold

Planning assumptions per sale:

- payment and delivery: 4% plus US$2;
- download bandwidth: less than US$0.10;
- variable support reserve: US$15;
- rounded variable cost: US$23;
- estimated contribution: US$126.

Eight sales per month produce about US$1,008 monthly contribution before fixed
engineering, legal, certificates, taxes, and owner labor. This is a target,
not a forecast.

Validation sequence:

1. Interview 10 developers who recently tuned MLX or llama.cpp. Ask about the
   last investigation before showing Loupe.
2. Run five offer conversations using the US$149 price and signed replay demo.
3. Require at least two paid purchases or written procurement intent before
   expanding adapter scope.
4. Track sample open, first real recording, successful stop, history reopen,
   evidence export, and a second use within seven days. Do not add analytics;
   collect this in consented onboarding calls.
5. Stop or reposition if buyers consistently choose free Anubis OSS or
   mlx-Chronos and do not value Loupe's evidence traceability.

## Ninety-second demo

1. Launch the signed candidate and select **Open sample session**.
2. State that the fixture is sanitized, includes no prompt text, and uses no
   model, helper, account, or API.
3. Scrub across prefill and decode while reading process RSS, swap, GPU, and
   thermal values from the shared cursor.
4. Open one finding and show its exact sample/event evidence.
5. Export JSON evidence and point to every present event, telemetry, and
   acquisition-metadata source SHA-256.
6. Open two deliberately mismatched benchmark reports and show that Loupe
   suppresses every delta.
7. End on **Record**, showing the two environment values for a real adapter.

## Recording shot list

Capture from the final signed candidate at 1440p or higher:

1. Overview with the primary action and local-data statement.
2. One-click sample load.
3. Timeline scrub across all lanes.
4. Finding jump and evidence detail.
5. JSON export in Finder or a text editor.
6. Comparison mismatch gate.
7. Record start, adapter connection, stop, and History reopen.
8. Optional helper permission explanation, without recording credentials.

Do not splice in source mockups or add fake player controls. Redact usernames
and local paths before publishing.

## Draft X post

> I built Loupe for a specific Apple Silicon debugging problem: a tokens-per-second number does not explain whether prefill, decode, memory pressure, or thermals changed. Loupe records MLX and llama.cpp request phases beside local Mac telemetry, blocks invalid A/B comparisons, and exports source-hashed evidence. Here is the sanitized replay workflow. [video]

Do not add a purchase link until the signed artifact, checkout, refund path,
and support contact are live.

## Draft community post

**Title:** I built a local MLX/llama.cpp profiler that refuses invalid run comparisons

I kept running into the same problem while looking at Apple Silicon inference:
throughput alone did not tell me whether a change came from prefill, decode,
KV growth, swap, or a thermal transition. I built a native macOS tool that
records runtime milestones and process/system telemetry on one monotonic clock.

The part I would most value feedback on is the evidence model. Every finding
links to the samples and events that triggered it. Benchmark deltas disappear
unless the model artifact, dependency lock, prompt corpus, runtime, hardware,
OS, warmup, and repeat counts match. Session data stays local by default.

The attached demo uses a committed sanitized fixture, not a cherry-picked live
run. Built-in event fields omit prompt/generated text; custom metadata and
benchmark inputs still require review before sharing. The project currently
supports MLX and loopback llama.cpp. The optional helper is only for GPU/power
telemetry.

Questions for people who tune local inference:

- Which investigation would this replace in your current workflow?
- Is a source-hashed review artifact useful, or is a normal CSV enough?
- Which mismatch has invalidated a benchmark for you in practice?

I am evaluating a US$149 one-time direct-download license, but paid demand is
not validated yet. I would rather hear that the free alternatives cover the
job than add another benchmark dashboard.

Before posting, read the target community's current self-promotion rules,
request moderator permission when required, disclose ownership and pricing,
avoid cross-posting, and stay to answer technical questions.

## First-customer outreach

Prepare, but do not send, a list of 20 people who have publicly described an
MLX/llama.cpp performance investigation. The owner should ask permission for a
20-minute workflow interview, offer the sanitized demo first, and make the
US$149 offer only after confirming the problem. Do not scrape private contact
data, automate messages, imply affiliation, or offer compensation that has not
been approved.

## Owner-controlled launch assets

- seller name, product domain, and support/security email;
- hosted checkout, tax/VAT handling, refund policy, and secure delivery;
- counsel-approved license, privacy, terms, and third-party notices;
- Developer ID certificate and notarization credentials;
- screenshots and video from the final signed candidate;
- actual customer quotes only with explicit permission.
