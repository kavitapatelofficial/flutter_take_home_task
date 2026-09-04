#!/usr/bin/env bash
# Fetches the DuckDB C library used by host-side runs (flutter test, tool/benchmark.dart).
#
# On a real device the library ships inside the app: the dart_duckdb pod/gradle
# module vendors it. Host-side test runs have no such bundle, so we drop the
# same version next to the project and point the loader at it (see
# test/support/duckdb_test_bootstrap.dart).
set -euo pipefail

VERSION="v1.4.2"   # must match dart_duckdb's vendored version
DEST="$(cd "$(dirname "$0")/.." && pwd)/.native"

case "$(uname -s)-$(uname -m)" in
  Darwin-*)        ASSET="libduckdb-osx-universal.zip" ;;
  Linux-x86_64)    ASSET="libduckdb-linux-amd64.zip" ;;
  Linux-aarch64)   ASSET="libduckdb-linux-arm64.zip" ;;
  *) echo "Unsupported host: $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

mkdir -p "$DEST"
if [ -f "$DEST/libduckdb.dylib" ] || [ -f "$DEST/libduckdb.so" ]; then
  echo "DuckDB native library already present in $DEST"
  exit 0
fi

echo "Downloading $ASSET ($VERSION)..."
curl -fsSL -o "$DEST/duckdb.zip" \
  "https://github.com/duckdb/duckdb/releases/download/$VERSION/$ASSET"
unzip -oq "$DEST/duckdb.zip" -d "$DEST"
rm -f "$DEST/duckdb.zip"
echo "DuckDB native library ready in $DEST"
