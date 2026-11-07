#!/usr/bin/env bash
# Usage: check-macos-bundle.sh <path/to/App.app> <max-minimum-macos>
# Fails if any Mach-O in the bundle requires a newer macOS than given, still
# loads a library from outside the bundle (other than the OS), or if the
# bundle's signature does not verify.
set -uo pipefail

app=${1:?usage: $0 <App.app> <max-minimum-macos>}
max=${2:?usage: $0 <App.app> <max-minimum-macos>}
fail=0

newer_than_max() { [ "$(printf '%s\n%s\n' "$max" "$1" | sort -V | tail -n1)" != "$max" ]; }

machos=0
while IFS= read -r -d '' f; do
  file -b "$f" | grep -q 'Mach-O' || continue
  machos=$((machos + 1))
  rel=${f#"$app"/}

  mins=$(otool -l "$f" | awk '
    /LC_BUILD_VERSION/     { b = 1 } b && $1 == "minos"   { print $2; b = 0 }
    /LC_VERSION_MIN_MACOSX/ { v = 1 } v && $1 == "version" { print $2; v = 0 }')
  if [ -z "$mins" ]; then
    echo "::error::$rel: no minimum macOS version recorded"; fail=1
  fi
  for m in $mins; do
    if newer_than_max "$m"; then
      echo "::error::$rel requires macOS $m (max allowed $max)"; fail=1
    fi
  done

  while IFS= read -r dep; do
    case $dep in
      @*|/usr/lib/*|/System/*) ;;
      *) echo "::error::$rel loads $dep from outside the bundle"; fail=1 ;;
    esac
  done < <(otool -L "$f" | tail -n +2 | awk '{print $1}')
done < <(find "$app" -type f -print0)

if [ "$machos" -eq 0 ]; then
  echo "::error::no Mach-O files found in $app"; fail=1
fi

if ! codesign --verify --deep --strict "$app" 2>&1; then
  echo "::error::code signature does not verify"; fail=1
fi

echo "checked $machos Mach-O files against macOS $max"
exit "$fail"
