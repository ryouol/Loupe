# Live llama.cpp capture — September 16, 2026

Loupe now records real llama.cpp requests on Roy's M1 Pro Mac (16 GB), through
its owner-only socket, SQLite recorder, portable replay, and JSON/CSV exporters.
This is an integration milestone, not a performance improvement claim.

Validated runtime: Homebrew llama.cpp 0.4.1, build 10964, commit b29c606e2.
Model: Qwen/Qwen2.5-0.5B-Instruct-GGUF, qwen2.5-0.5b-instruct-q4_k_m.gguf,
revision 9217f5db79a29953eb74d5343926648285ec7e67. SHA-256:
`74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db`.
Context 2048; one slot;
24 layers, 2 KV heads, head dimension 64, f16 K/V. Requests use temperature 0,
seed 42 and disabled prompt caching. KV bytes are architecture estimates;
process RSS and system memory/thermal samples remain separately attributed.

Two completed 128-token requests each produced 134 valid events, plus 9 and 8
system samples. Both replayed and exported with zero parser drops and exactly
zero event acquisition losses. A third request was terminated after 300 ms;
its request start survived, replay marked it incomplete, and it contributed no
completed-request metrics. Its acquisition loss total correctly remains unknown
without the producer's final summary. Telemetry has zero known losses; shutdown
can leave the upstream acquisition total unknown, which exports preserve.

The first live run exposed a real recorder bug: cancelling the sampler on stop
passed cancellation to GRDB while flushing its accepted tail. The original
capture retained 38 events but lost all four telemetry samples. A bounded,
independently awaited write now saves that tail. The archive retains the failing
capture. Other fixes persist request start before HTTP, require a terminal chunk
before claiming success, reject malformed SSE instead of skipping it, use server
cumulative token counts, and distinguish token limits from normal stops.

Timing boundaries: TTFT is client request start to first nonempty streamed
content. Prefill placement is reconstructed from server prompt_ms, not an
independently observed GPU boundary. Request end uses the terminal chunk arrival;
reported predicted_ms is retained separately. Current llama.cpp's displayed rate
excludes the first token, whereas Loupe's normalized rate divides all reported
output tokens by that duration. These rates must not be compared as identical.
Per-token events are flushed after the exchange; cancellation preserves the
attempt but not the buffered token prefix. No GPU kernel-time claim is made.

## Run it

Install `llama.cpp` with Homebrew and obtain the pinned GGUF above. In a terminal:

```sh
llama-server -m "$MODEL" --host 127.0.0.1 --port 18080 -c 2048 --parallel 1 --metrics
```

From the Loupe repository, build and run the repeatable integration check:

```sh
swift build
python3 scripts/check-llamacpp-live.py --output /tmp/loupe-llama-evidence \
  --kv-layers 24 --kv-head-dim 64 --kv-heads 2
```

The output directory must be new. This produces two completed recordings and a
cancelled recording, replays each through the app's parser, and checks JSON/CSV
export. To use the app, start recording, then run `loupe-llamacpp` with the same
server and KV flags; its default socket is the app's recording socket. Pipe a
chat-formatted prompt using `--prompt-stdin`. `loupe-capture <storage-root>` offers
the same recorder without the UI: its first stdout line gives socket, run ID and
session path; send a newline to stop, then use `loupe-export` on that path.

Evidence: `investigations/llamacpp-2026-09-16/recordings.tar.gz`, summary and SHA-256
manifest. Full Xcode is absent locally; builds and live checks run here, XCTest
runs in macOS CI. This does not provide signing, notarization or GUI validation.
