#!/usr/bin/env bash
# Verify the built Hex archive, not a checkout or an existing build directory.
set -euo pipefail
if [[ $# != 1 ]]; then
  echo "Usage: $0 /path/to/laughter.tar" >&2
  exit 2
fi
root=$(cd "$(dirname "$0")/.." && pwd)
archive=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
work=$(mktemp -d "${TMPDIR:-/tmp}/laughter-package.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/envelope" "$work/package" "$work/consumer"
tar -xf "$archive" -C "$work/envelope"
tar -xzf "$work/envelope/contents.tar.gz" -C "$work/package"
for file in lib/laughter/nif/generated_stubs.ex \
  native/laughter_nif/src/generated_rewrite.rs \
  native/laughter_nif/src/generated_events.rs \
  native/laughter_nif/Cargo.lock CHANGELOG.md bench/README.md; do
  test -f "$work/package/$file" || { echo "Missing packaged file: $file" >&2; exit 1; }
done
if find "$work/package" -type f | grep -E '/(_build|deps|target|priv)/|\.(so|dylib|dll)$'; then
  echo "Archive contains build artifacts" >&2
  exit 1
fi
cp "$root/test/fixtures/package_consumer/"*.exs "$work/consumer/"
export LAUGHTER_PACKAGE_PATH="$work/package"
export MIX_ENV=prod
# Do not accidentally reuse the caller's build/dependency trees.
unset MIX_BUILD_PATH MIX_BUILD_ROOT MIX_DEPS_PATH MIX_LOCKFILE
cd "$work/consumer"
mix deps.get
mix compile --warnings-as-errors
mix run smoke.exs
