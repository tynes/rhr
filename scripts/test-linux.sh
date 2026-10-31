#!/usr/bin/env bash
# Runs the RHRCore package tests on Linux.
# GRDB needs SQLite's snapshot API, which distribution builds usually omit, so this builds a
# private snapshot-enabled libsqlite3 once (recipe from github.com/ryanbr/noop docs/BUILD.md).
set -euo pipefail
SQLITE_DIR="${SQLITE_SNAPSHOT_DIR:-$HOME/.cache/sqlite-snapshot}"
if [ ! -f "$SQLITE_DIR/libsqlite3.so" ]; then
  mkdir -p "$SQLITE_DIR"
  curl -fsSLo "$SQLITE_DIR/sqlite.zip" https://sqlite.org/2026/sqlite-amalgamation-3530400.zip
  unzip -p "$SQLITE_DIR/sqlite.zip" sqlite-amalgamation-3530400/sqlite3.c > "$SQLITE_DIR/sqlite3.c"
  unzip -p "$SQLITE_DIR/sqlite.zip" sqlite-amalgamation-3530400/sqlite3.h > "$SQLITE_DIR/sqlite3.h"
  echo "b1dd5d74ec7f29055a6684fa06fb3c2f6821c87dd38f9a458dfd2e8a1db28189  $SQLITE_DIR/sqlite3.c" | sha256sum --check
  cc -O2 -shared -fPIC -DSQLITE_ENABLE_SNAPSHOT=1 "$SQLITE_DIR/sqlite3.c" -o "$SQLITE_DIR/libsqlite3.so.0"
  ln -sf libsqlite3.so.0 "$SQLITE_DIR/libsqlite3.so"
fi
cd "$(dirname "$0")/../Packages/RHRCore"
LD_LIBRARY_PATH="$SQLITE_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  swift test -Xcc -I"$SQLITE_DIR" -Xlinker -L"$SQLITE_DIR" "$@"
