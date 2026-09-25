# Agent guidelines

## Build

```sh
mix deps.get
LAUGHTER_BUILD=1 mix compile
LAUGHTER_BUILD=1 mix ci
LAUGHTER_BUILD=1 mix docs --warnings-as-errors
```

Released packages use precompiled NIFs by default. Set `LAUGHTER_BUILD=1` for
checkout development and any compilation that touches Rust code. Do not test
changed Rust against downloaded release binaries.

Use the shared `elixir-vibe/actions` Rustler CI and release workflows. Keep this
repository's workflow files thin; do not add custom package-consumer projects or
archive-validation scripts. Full development checks require the toolchain in
`.tool-versions`; production compilation also supports Elixir 1.15/OTP 26.

## Native boundary

`native/laughter_nif` is the single native crate. RustQ is development-only;
generated sources are checked in. Edit `codegen/` and the shared content schema,
not generated Rust or Elixir stubs. Prefer RustQ structural generation, ordinary
Elixir macros, and semantic AST tools over string-based source transformations.
Handwritten Rust owns resource lifetimes, synchronization, and buffers.

Keep the loader's target list and NIF ABI aligned with the release workflow.
Both currently use NIF 2.15 and the shared five-target matrix. Rustler's Cargo
features explicitly select that ABI. Preserve the musl Cargo configuration in
the package.

## Release

1. Align `@version` in `mix.exs` and the native Cargo version/lockfile.
2. Roll `CHANGELOG.md`'s Unreleased section into the dated version section.
3. Run source-build quality checks, then commit the release preparation.
4. Tag `vX.Y.Z` and push the commit and tag.
5. Wait for all five precompiled targets to succeed.
6. Download checksums:
   ```sh
   LAUGHTER_BUILD=1 mix rustler_precompiled.download Laughter.Nif --all
   ```
7. Commit and push `checksum-Elixir.Laughter.Nif.exs`. This commit comes AFTER
   the binaries finish building; the release tag stays on the preparation commit.
8. Verify a clean precompiled build without `LAUGHTER_BUILD`, then publish with
   `mix hex.publish`. The package must include the checksum file.
9. Verify Hex, HexDocs, release assets, and remote tag. The workflow creates the
   GitHub Release: edit it rather than creating a second release. Its title must
   be exactly `vX.Y.Z`, and its body exactly the matching changelog section body.

Never force-push or move a release tag, or overwrite its native binaries: this
can invalidate published checksums. Fix released packages with a patch release.
Do not publish or tag unless explicitly requested.
