# Rewrite benchmarks

`mix run bench/rewrite.exs` compares declarative, streamed, and legacy-callback
rewrites of one larger document. `mix run bench/load.exs` exercises concurrency
and native lifecycle behavior. Neither is a statistical performance suite.

## Load benchmark

```sh
JOBS=2000 ROUNDS=3 ELEMENTS=100 CHUNK_BYTES=4096 CONCURRENCY=1,8,32 \
  mix run bench/load.exs
```

These are the defaults. Each case processes `JOBS` independent documents with
at most `CONCURRENCY` tasks. Each dynamic document starts a fresh session/native
worker. All modes set the same attribute on each `p`; output size and CRC32 are
checked against a whole-document rewrite. Dynamic mode replies once per element;
`dynamic_no_matches` uses native rules with an unmatched dynamic selector to
isolate the opt-in session overhead. Warmup exercises all four modes.

CSV reports:

- End-to-end documents/second, including task/session startup and shutdown.
- Per-document p95 latency (including dynamic session startup, excluding task startup).
- Number of samples and maximum sampler timer lateness on the BEAM.
- Maximum observed mailbox length of an owner task or session, not a VM-wide sum.
- Observed peak native worker count and reserved bounded-output-buffer capacity.
- Sampled BEAM memory growth and post-quiescence process RSS/change, in MiB.

Sampling runs every 10ms, adds overhead, and can miss short-lived allocations or
mailbox bursts. `n/a` means no samples were collected; even a sampled zero is not
proof that a transient allocation never occurred. Timer lateness includes sampler
work and host scheduling noise. RSS uses `ps` where available; it is **not peak
RSS**, and includes allocator caches, thread stacks, code, and BEAM memory.
Native counters exclude legacy callback workers, LOL HTML allocations, input,
BEAM binaries, and whole-document output vectors. All cases wait for tracked
workers/buffers/capacity to reach `{0, 0, 0}` before continuing. This final native
quiescence wait and the subsequent RSS measurement are outside throughput timing.

For multi-chunk documents, increase `ELEMENTS` or decrease `CHUNK_BYTES`. Increase
`JOBS` for meaningful sampling of short native-only cases. Repeated rounds in the
same VM help distinguish allocator warmup from continuing memory growth.

## Local baseline

Apple M5, Darwin arm64, OTP 27, Elixir 1.19.5, 10 BEAM schedulers; Rust 1.95.0,
release native build. Default workload above: 3,692 input bytes and 100 elements
per document. Median throughput across three rounds:

| Mode | Concurrency 1 | Concurrency 8 | Concurrency 32 |
| --- | ---: | ---: | ---: |
| Native rules | 21,275 docs/s | 76,511 docs/s | 97,800 docs/s |
| Native streaming | 15,668 docs/s | 46,578 docs/s | 59,605 docs/s |
| Dynamic session, no matches | 9,117 docs/s | 19,613 docs/s | 22,552 docs/s |
| Dynamic, 100 replies/document | 921 docs/s | 1,556 docs/s | 2,421 docs/s |

Observed over this run:

- All 36 cases returned tracked native resources to zero.
- Maximum sampled mailbox length: 5 messages; sampler timer lateness: 18ms.
- At concurrency 32, dynamic mode reached 32 tracked workers and 32 MiB reserved
  output-buffer capacity (the default is 1 MiB/session, not all resident).
- Post-quiescence RSS at the end of each round: 122.80, 124.70, 124.67 MiB. This
  short run is consistent with warmup/retention, not proof that all memory is leak-free.
- Dynamic p95 document latency at concurrency 32 varied from 14.39 to 33.22ms,
  illustrating host/load variability. Native high-concurrency cases had only
  1–4 samples per case, so their sampled peaks are especially weak evidence.

An additional 200-document run with 1,000 elements/document (37,893 bytes,
multiple 4,096-byte chunks) at concurrency 32 also returned all tracked resources
to zero. It measured 13,572 native, 12,071 streamed, 3,583 unmatched-dynamic, and
250 fully dynamic documents/second; sampled timer lateness stayed at or below 5ms.
This is a single additional run, not a stable throughput estimate.

The existing 71,000-byte / 3,000-match comparison measured medians of 0.89ms
native, 0.95ms streaming, and 13.26ms legacy callbacks (five runs each).

**Implication:** keep declarative transformations on the native fast path.
Per-element messaging is expensive, while an unmatched dynamic session is still
substantially more expensive than a native rewrite. This does not establish that
worker pooling is the right optimization: profile startup versus message costs
on a representative workload before changing worker ownership or semantics.

## Hardening tests

```sh
mix test test/laughter/rewriter/lifecycle_test.exs test/laughter/rewriter/equivalence_test.exs
```

Lifecycle tests serialize around VM-global counters and cover forced process
termination, owner death, both cancel/reply and delivered-timeout/reply orderings,
stale timer delivery during a later request, real native watchdog races, repeated
EOF/startup-error/overflow cleanup, and resource destruction without explicit close.
Delivered-timer orderings use a suspended session and queued owner calls rather
than relying on sleep timing. Real watchdog tests accept either legitimate race
winner but require one terminal event and prompt cleanup.

Equivalence tests use 120 fixed random seeds to vary mutations and byte-level
chunk boundaries (including split UTF-8, entities, empty chunks, and incomplete
EOF tokens). Whole-document, streaming, and dynamic results must match exactly.
They use sibling `p` elements and a stable tag selector so the compared modes
have equivalent matching semantics; they are not exhaustive HTML fuzzing.
