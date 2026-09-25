# Development

[Back to the README](../README.md)

Use the toolchain in `.tool-versions` for development. RustQ generation requires
Elixir 1.19+ and Rust 1.91+; consumers do not need RustQ. Generated Rust and Elixir
stubs are checked in, so normal dependency builds do not run the generator.

## Native boundary ownership

| Source | Owns |
| --- | --- |
| `codegen/rewrite.exs` | Typed NIF declarations, codecs, resource registration |
| `lib/laughter/rewriter/content.ex` + `codegen/content.exs` | Content-operation list, builders, native dispatch |
| `codegen/events.exs` | Typed worker-event and envelope encoders |
| `codegen/nif.exs` | Elixir stubs derived from NIF declarations and legacy Rust signatures |

Do not edit `native/laughter_nif/src/generated_*.rs` or
`lib/laughter/nif/generated_stubs.ex` by hand. Legacy export policy lists names,
not arities; RustQ reads signatures and excludes the injected `Env` argument.
Ownership, synchronization, buffering, and cancellation remain explicit Rust.

```sh
export LAUGHTER_BUILD=1
mix deps.get
mix rustq.gen
mix ci
mix docs --warnings-as-errors
cargo clippy --manifest-path native/laughter_nif/Cargo.toml --locked -- -D warnings
```

`mix ci` checks compilation, tests, generated-source freshness, Credo, Dialyzer,
and duplication. See `test/README.md` in the repository for suite organization.

## Native builds and releases

Consumers use precompiled NIFs by default. Set `LAUGHTER_BUILD=1` when developing
from a checkout or changing Rust code so tests exercise the current sources.

CI uses the shared `elixir-vibe/actions` Rustler workflow. It runs the full suite
on Elixir 1.19/OTP 27 and checks production compilation on Elixir 1.15/OTP 26.
Tag pushes use the shared precompilation workflow to attach native binaries to
the GitHub Release. Download and commit their checksums before publishing to
Hex; see `AGENTS.md` in the repository for the release sequence.

## Benchmarks and diagnostics

```sh
mix run bench/rewrite.exs
JOBS=2000 ROUNDS=3 ELEMENTS=100 CONCURRENCY=1,8,32 mix run bench/load.exs
```

See [benchmark methodology and local results](../bench/README.md).

The internal `Laughter.Nif.rewrite_stats()` reports tracked dynamic worker
lifetimes, bounded output buffers, and their reserved capacity. It excludes legacy
workers, parser/input/BEAM memory, and whole-document output allocations.
Concurrent snapshots are eventually consistent, not an atomic memory profile.
Lifecycle tests wait for all three counters to return to zero.
