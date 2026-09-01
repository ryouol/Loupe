# Product decision: evidence-first local inference profiler

Research snapshot and source access date: **2026-09-01**.

## Decision

Loupe is a paid, local-first diagnostic workspace for developers and
performance consultants shipping MLX or llama.cpp inference on Apple Silicon.
It is not a generic Activity Monitor, a hosted observability service, or a
benchmark leaderboard.

The painful job is: **When a local model becomes slow, memory-hungry, or
inconsistent, show which inference phase changed, what the Mac was doing at
that moment, and produce evidence another engineer can inspect.**

The concrete end state is a durable local session with request phases and
system telemetry on one clock, evidence-linked findings, a safely gated run
comparison, and a portable JSON or CSV report.

## Primary customer and reader

The first buyer is an independent macOS AI developer, performance engineer, or
consultant who regularly changes models, quantization, context length, or
runtime configuration. Their client prompts and unreleased model identifiers
cannot be sent to a hosted profiler. They currently combine runtime logs,
Activity Monitor, command-line telemetry, and spreadsheets, then spend time
proving whether two measurements were actually comparable.

The repository is suited to this job because it already has native SwiftUI,
MLX and llama.cpp adapters, correlated monotonic timestamps, local SQLite,
replay fixtures, and benchmark comparison logic. Productizing those assets is
smaller and more defensible than adding a cloud control plane.

## Evidence and alternatives

The market has strong free alternatives. This makes willingness-to-pay the
main unresolved business risk.

| Alternative | Verified capability | Implication for Loupe |
|---|---|---|
| [Apple Instruments](https://developer.apple.com/library/archive/documentation/AnalysisTools/Conceptual/instruments_help-collection/Chapter/Chapter.html) | Records multiple system and process instruments on a shared timeline as part of Xcode. [Xcode tools do not require a paid Developer Program membership](https://developer.apple.com/xcode/resources/). | Powerful and free, but it does not understand Loupe's MLX/llama.cpp request protocol or produce Loupe's evidence bundle. |
| [MLX LM benchmark](https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/BENCHMARKS.md) | Measures prompt and generation throughput and memory for a fixed model invocation. | A credible free baseline for headline benchmark numbers. Loupe must sell diagnosis and comparability, not tokens per second alone. |
| [llama.cpp server metrics](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md) | Exposes Prometheus counters and gauges when metrics are enabled. | Loupe should reuse runtime truth and add local phase correlation, not claim to replace server monitoring. |
| [Anubis OSS](https://github.com/uncSoft/anubis-oss) | A free GPL-3.0 native macOS benchmark app with TTFT, GPU/CPU, memory, thermal, power, history, replay, and exports. | This is the closest direct competitor and overlaps substantially. Loupe cannot claim category uniqueness. |
| [mlx-Chronos](https://github.com/igurss/mlx-chronos) | A free benchmark CLI with sealed JSON, engine comparisons, cooldown controls, and a community leaderboard. | Provenance and reproducibility are expected features, not sufficient differentiation by themselves. |

Current community discussion shows active demand for reproducible Apple
Silicon measurements, but not proven paid demand. One project reported that
results were otherwise scattered and incomparable before collecting nearly
10,000 community runs ([r/LocalLLaMA discussion](https://www.reddit.com/r/LocalLLaMA/comments/1rrvyyh/almost_10000_apple_silicon_benchmark_runs/)). A separate tool request
specifically asked for MLX support, memory bandwidth, and memory-pressure
measurement ([benchmark-tool feedback](https://www.reddit.com/r/LocalLLaMA/comments/1r0fz1h/opensource_apple_silicon_local_llm_benchmarking/)).
These discussions support the problem, not the proposed price.

MLX and llama.cpp remain active moving targets. MLX is an Apple-led framework
for Apple Silicon ([Apple open-source overview](https://opensource.apple.com/projects/)),
and llama.cpp continues to publish Apple Silicon builds
([llama.cpp releases](https://github.com/ggml-org/llama.cpp/releases)). Strict
runtime and dependency provenance is therefore a product requirement.

## Narrow differentiation

Loupe's wedge is a private engineering evidence workflow:

1. Instrument a developer-controlled MLX or llama.cpp run without built-in
   prompt or generated-text event fields.
2. Inspect model load, prefill, decode, KV growth, process RSS, memory, swap,
   thermal state, GPU, and power on one linkable timeline.
3. Explain findings with the exact sample and event timestamps that triggered
   each rule.
4. Refuse benchmark deltas unless the run spec, prompt corpus digest, runtime,
   model artifact, dependency lock, host, OS, warmup, and repeat counts match.
5. Export source-hashed evidence without an account, leaderboard submission,
   analytics SDK, or cloud upload path.

This differentiation is narrow and falsifiable. If target users prefer the
broader free Anubis workflow and do not value evidence traceability or strict
comparison gates, Loupe should not proceed to a paid launch.

## Commercial motion and unit economics

The recommended motion is one direct-download early-access license:

- **US$149 one time** for one named developer, use on that person's Macs, and
  12 months of updates.
- No subscription, usage charge, cloud account, or unlimited free trial.
- The bundled replay remains a zero-cost, zero-compute evaluation path.

Planning assumptions per sale are 4% plus US$2 for payment and delivery, less
than US$0.10 of download cost, and a US$15 variable support reserve. Rounded
variable cost is **US$23**, leaving about **US$126 contribution per sale**.
Eight sales per month would produce about **US$1,008 monthly contribution**
before fixed development, legal, certificates, taxes, and owner time. These
are planning assumptions, not measured economics.

The primary acquisition channel is a technical replay video and methodology
post in Apple Silicon inference communities, especially r/LocalLLaMA and MLX
developer discussions, followed by permission-based outreach to consultants
and maintainers who publicly discuss performance investigations. Community
rules and self-promotion limits must be checked before posting.

## Scope and explicit non-goals

In scope:

- native local recording, history, replay, and evidence export;
- MLX and loopback llama.cpp adapters;
- comparable benchmark reports with fail-closed gates;
- optional signed helper for GPU and power fields;
- direct signed and notarized DMG distribution.

Out of scope for this release:

- cloud sync, accounts, collaboration, public leaderboards, or telemetry;
- remote llama.cpp endpoints;
- an in-app license server or checkout SDK;
- automatic diagnoses without inspectable rules and evidence;
- broad runtime support before customers validate the first two adapters;
- claims that an unsigned build is distributable.

## Claims policy

Allowed after the corresponding workflow passes:

- local-first and no intentional product analytics;
- built-in adapters omit prompt/generated text from protocol events and
  sanitize generation failures;
- same-user adapter ingest and opaque owner-only session files;
- evidence-linked rules and source-hashed exports;
- mismatched benchmark dimensions suppress deltas;
- MLX and loopback llama.cpp support at the tested versions.

Do not claim:

- category uniqueness, guaranteed speedups, automatic root-cause accuracy, or
  complete hardware coverage;
- tamper-proof or cryptographically signed evidence;
- security audit, App Store compatibility, notarization, or production
  signing without attached evidence;
- customer adoption, revenue, or willingness to pay before real purchases;
- support for a runtime/model/macOS combination that was not tested.

## Licensing conclusion

Repository history currently shows one author identity, Roy Luo. The new
top-level license reserves rights for a commercial direct download. The owner
must still confirm that the copyright identity is correct and that every
committed asset was created or licensed for this use.

Direct Swift dependencies GRDB and Yams are MIT licensed. MLX is described by
Apple as permissively MIT licensed
([WWDC25 MLX session](https://developer.apple.com/videos/play/wwdc2025/315/));
the optional MLX dependency tree still needs a generated release inventory.
Loupe does not bundle llama.cpp or model weights. IOReport is a private macOS
framework loaded at runtime, so compatibility and distribution review remain
release risks even though no third-party binary is copied into the app.

## Assumptions requiring owner verification

- copyright ownership and the legal seller name;
- support and security contact addresses;
- Developer ID and notarization access;
- counsel approval of the license, privacy draft, terms, IOReport use, refund
  policy, and third-party inventory;
- hosted-checkout provider, tax handling, and secure download delivery;
- at least ten problem interviews and five paid-offer conversations;
- supported Apple Silicon and macOS matrix based on actual signed builds.
