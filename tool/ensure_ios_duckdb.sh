#!/usr/bin/env bash
# dart_duckdb 1.4.4's podspec downloads
#   .../releases/download/v1.4.4/duckdb-framework-ios.zip
# which 404s. GitHub only ships the iOS zip on v1.4.2 (the DuckDB version
# 1.4.4 actually bundles). Drop that framework into the pub-cache copy so
# `pod install` skips the broken curl.
#
# The zip is an iPhoneOS device binary. On Apple Silicon we stamp it as
# iossim so the iPhone Simulator can link it.
set -euo pipefail

if [[ -n "${PUB_CACHE:-}" ]]; then
  PKG="${PUB_CACHE}/hosted/pub.dev"
else
  PKG="${HOME}/.pub-cache/hosted/pub.dev"
fi

DIR="$(find "$PKG" -maxdepth 1 -type d -name 'dart_duckdb-*' | sort -V | tail -n 1)"
if [[ -z "$DIR" ]]; then
  echo "dart_duckdb is not in the pub cache. Run flutter pub get first." >&2
  exit 1
fi

DEST="$DIR/ios/Libraries/release"
BIN="$DEST/duckdb.framework/duckdb"
mkdir -p "$DEST"

if [[ ! -d "$DEST/duckdb.framework" ]]; then
  rm -f "$DIR/ios/duckdb-framework-ios.zip"
  URL="https://github.com/TigerEyeLabs/duckdb-dart/releases/download/v1.4.2/duckdb-framework-ios.zip"
  TMP="$(mktemp -d)"
  echo "downloading $URL"
  curl -L --fail -o "$TMP/duckdb-framework-ios.zip" "$URL"
  unzip -o "$TMP/duckdb-framework-ios.zip" -d "$DEST"
  rm -rf "$TMP"
  echo "wrote $DEST/duckdb.framework"
fi

if [[ "$(uname -s)" == "Darwin" && -f "$BIN" ]]; then
  if ! xcrun vtool -show-build "$BIN" 2>/dev/null | grep -q IOSSIMULATOR; then
    cp "$BIN" "$BIN.iphoneos"
    xcrun vtool -arch arm64 -set-build-version iossim 15.0 18.0 -replace -output "$BIN" "$BIN.iphoneos"
    chmod +x "$BIN"
    codesign --force --sign - "$BIN" >/dev/null
    echo "stamped $BIN as iOS Simulator"
  fi
fi
