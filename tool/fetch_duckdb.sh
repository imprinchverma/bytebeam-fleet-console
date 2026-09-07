#!/usr/bin/env bash
set -euo pipefail
# Downloads the DuckDB shared library used by dart_duckdb on Linux desktop/tests.
# Android/iOS builds fetch their own binaries via the plugin.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/native/libduckdb.so"
URL="https://github.com/duckdb/duckdb/releases/download/v1.4.2/libduckdb-linux-amd64.zip"
if [[ -f "$DEST" ]]; then
  echo "already present: $DEST"
  exit 0
fi
mkdir -p "$ROOT/native" /tmp/duckdb-extract
curl -L --fail -o /tmp/libduckdb.zip "$URL"
unzip -o /tmp/libduckdb.zip -d /tmp/duckdb-extract
cp /tmp/duckdb-extract/libduckdb.so "$DEST"
echo "wrote $DEST"
