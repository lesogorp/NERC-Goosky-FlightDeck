#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$repo_root/build"
archive="$build_dir/NERC_Goosky_FlightDeck.zip"

mkdir -p "$build_dir"

if command -v texluac >/dev/null 2>&1; then
  texluac -p "$repo_root/SDCARD/WIDGETS/NERC_GSkyFD/main.lua"
  texluac -p "$repo_root/SDCARD/SCRIPTS/TOOLS/GooskySetup.lua"
fi

if command -v texlua >/dev/null 2>&1; then
  (cd "$repo_root" && texlua tests/run_tests.lua)
elif command -v lua >/dev/null 2>&1; then
  (cd "$repo_root" && lua tests/run_tests.lua)
else
  echo "Lua 5.3 or texlua is required to run tests." >&2
  exit 1
fi

archive_tmp_dir="$(mktemp -d)"
trap 'rmdir "$archive_tmp_dir" 2>/dev/null || true' EXIT

(
  cd "$repo_root/SDCARD"
  zip -q -r "$archive_tmp_dir/NERC_Goosky_FlightDeck.zip" README.txt IMAGES WIDGETS SCRIPTS
)

mv "$archive_tmp_dir/NERC_Goosky_FlightDeck.zip" "$archive"
unzip -tq "$archive"
sha256sum "$archive"

