#!/usr/bin/env bash
# Fetches the DuckDB C library used by host-side runs (flutter test, tool/benchmark.dart).
#
# On a real device the library ships inside the app: the dart_duckdb pod/gradle
# module vendors it. Host-side test runs have no such bundle, so we drop the
# same version next to the project and point the loader at it (see
# test/support/duckdb_test_bootstrap.dart).
set -euo pipefail

VERSION="v1.2.1"   # must match the engine dart_duckdb 1.2.2 vendors
DEST="$(cd "$(dirname "$0")/.." && pwd)/.native"

case "$(uname -s)-$(uname -m)" in
  Darwin-*)        ASSET="libduckdb-osx-universal.zip" ;;
  Linux-x86_64)    ASSET="libduckdb-linux-amd64.zip" ;;
  Linux-aarch64)   ASSET="libduckdb-linux-arm64.zip" ;;
  *) echo "Unsupported host: $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

mkdir -p "$DEST"
if [ ! -f "$DEST/libduckdb.dylib" ] && [ ! -f "$DEST/libduckdb.so" ]; then
  echo "Downloading $ASSET ($VERSION)..."
  curl -fsSL -o "$DEST/duckdb.zip" \
    "https://github.com/duckdb/duckdb/releases/download/$VERSION/$ASSET"
  unzip -oq "$DEST/duckdb.zip" -d "$DEST"
  rm -f "$DEST/duckdb.zip"
  echo "DuckDB native library ready in $DEST"
else
  echo "DuckDB native library already present in $DEST"
fi

if [[ "$(uname -s)" == "Darwin" ]]; then
  PUB_DIR="${PUB_CACHE:-$HOME/.pub-cache}/hosted/pub.dev"
  for plugin_dir in "$PUB_DIR"/dart_duckdb-*; do
    if [ -d "$plugin_dir/macos" ]; then
      mkdir -p "$plugin_dir/macos/Libraries/release"
      cp -f "$DEST/libduckdb.dylib" "$plugin_dir/macos/Libraries/release/libduckdb.dylib"
      echo "DuckDB native library ready in $plugin_dir/macos/Libraries/release"
    fi
  done
fi

