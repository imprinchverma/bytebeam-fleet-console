#!/usr/bin/env bash
set -euo pipefail
# Downloads the DuckDB shared library used by dart_duckdb in VM tests.
# Android/iOS builds fetch their own binaries via the plugin.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="v1.4.2"
mkdir -p "$ROOT/native"

if [[ "$(uname -s)" == "Darwin" ]]; then
  DEST="$ROOT/native/libduckdb.dylib"
  URL="https://github.com/duckdb/duckdb/releases/download/${VERSION}/libduckdb-osx-universal.zip"
else
  DEST="$ROOT/native/libduckdb.so"
  URL="https://github.com/duckdb/duckdb/releases/download/${VERSION}/libduckdb-linux-amd64.zip"
fi

if [[ -f "$DEST" ]]; then
  echo "already present: $DEST"
  exit 0
fi

TMP="$(mktemp -d)"
curl -L --fail -o "$TMP/libduckdb.zip" "$URL"
unzip -o "$TMP/libduckdb.zip" -d "$TMP"
if [[ "$(uname -s)" == "Darwin" ]]; then
  cp "$TMP/libduckdb.dylib" "$DEST"
else
  cp "$TMP/libduckdb.so" "$DEST"
fi
echo "wrote $DEST"
