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
mix deps.get
mix rustq.gen
mix ci
mix docs --warnings-as-errors
cargo clippy --manifest-path native/laughter_nif/Cargo.toml --locked -- -D warnings
```

`mix ci` checks compilation, tests, generated-source freshness, Credo, Dialyzer,
and duplication. See `test/README.md` in the repository for suite organization.

## Package checks

From a repository checkout:

```sh
mix hex.build --output /tmp/laughter.tar
scripts/check-package.sh /tmp/laughter.tar
```

The script extracts the archive into a fresh consumer project, resolves consumer
dependencies, compiles from scratch, and exercises parsing, callbacks, plans,
streams, and sessions without RustQ. Its fixture is in
`test/fixtures/package_consumer/`; the fixture and script are repository tooling,
not part of the published package. CI is configured to test the same archive on
Elixir 1.15/OTP 26 and Elixir 1.19/OTP 27.

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
