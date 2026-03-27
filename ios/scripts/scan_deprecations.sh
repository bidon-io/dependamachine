#!/usr/bin/env bash
set -euo pipefail

# Shared deprecation scanner for iOS adapter projects.
#
# Usage: scan_deprecations.sh [repo_path] [--adapter-pattern PATTERN]
#
# Environment:
#   ADAPTER_PATTERN   - Glob/regex pattern for adapter dirs (default: BidonAdapter[A-Za-z]+)
#   ADAPTERS_DIR      - Root directory for adapters (default: Adapters)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO="${1:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# Parse named arguments
ADAPTER_PATTERN="${ADAPTER_PATTERN:-BidonAdapter[A-Za-z]+}"
ADAPTERS_DIR="${ADAPTERS_DIR:-Adapters}"

for arg in "$@"; do
  case "$arg" in
    --adapter-pattern=*) ADAPTER_PATTERN="${arg#*=}" ;;
    --adapters-dir=*)    ADAPTERS_DIR="${arg#*=}" ;;
  esac
done

cd "$REPO"

OUT="build/reports/deprecations"
mkdir -p "$OUT"
RAW="$OUT/raw.txt"
: > "$RAW"

# 1) Collect deprecation lines from all xcactivitylogs (macOS bash 3.2 compatible)
find ~/Library/Developer/Xcode/DerivedData -type f -path "*/Logs/Build/*.xcactivitylog" -print0 2>/dev/null \
  | while IFS= read -r -d '' ACT; do
      if command -v file >/dev/null 2>&1 && file "$ACT" 2>/dev/null | grep -qi 'gzip'; then
        if command -v gzcat >/dev/null 2>&1; then
          gzcat "$ACT" 2>/dev/null | strings | grep -ai 'deprecated' || true
        else
          zcat "$ACT" 2>/dev/null | strings | grep -ai 'deprecated' || true
        fi
      else
        strings "$ACT" | grep -ai 'deprecated' || true
      fi
    done >> "$RAW"

# 1b) Collect from .xcresult bundles
find ~/Library/Developer/Xcode/DerivedData -type d \( -path "*/Logs/Build/*.xcresult" -o -path "*/Logs/Test/*.xcresult" \) 2>/dev/null \
  | while IFS= read -r RES; do
      if command -v xcrun >/dev/null 2>&1; then
        xcrun xcresulttool get --path "$RES" --format json --legacy 2>/dev/null \
          | grep -ai 'deprecated' || true
      fi
    done >> "$RAW"

# 2) Scan latest fastlane xcodebuild.log
LOG="$(ls -t ~/Library/Logs/fastlane/xcbuild/*/xcodebuild.log 2>/dev/null | head -n1 || true)"
if [ -f "$LOG" ]; then
  grep -ai 'deprecated' "$LOG" || true
fi >> "$RAW"

# 3) Unique lines
sort -u "$RAW" > "$OUT/deprecations.txt" || true

# 4) Detect adapters (multiple strategies)
ls -1 "$ADAPTERS_DIR" 2>/dev/null | grep -E "^${ADAPTER_PATTERN}" | sort -u > "$OUT/all_adapters.txt" || true
: > "$OUT/adapters.txt"

# 4a) Path-based extraction
grep -aoE "${ADAPTERS_DIR}/${ADAPTER_PATTERN}" "$OUT/deprecations.txt" \
  | sed -E "s#.*${ADAPTERS_DIR}/##" \
  | sort -u >> "$OUT/adapters.txt" || true

if [ -s "$OUT/deprecations.txt" ] && [ -s "$OUT/all_adapters.txt" ]; then
  while IFS= read -r ADP; do
    if grep -aiqE "(${ADAPTERS_DIR}/|/)?${ADP}(/|\\.| |:|$)|(^|[^A-Za-z0-9_])${ADP}([^A-Za-z0-9_]|$)" "$OUT/deprecations.txt"; then
      echo "$ADP" >> "$OUT/adapters.txt"
    fi
  done < "$OUT/all_adapters.txt"

  # 5) Build filename->adapter map
  : > "$OUT/basename_to_adapter.txt"
  find "$ADAPTERS_DIR" -type f \( -name '*.swift' -o -name '*.mm' -o -name '*.m' -o -name '*.h' -o -name '*.hpp' -o -name '*.cpp' \) 2>/dev/null \
    | while IFS= read -r P; do
        BN="$(basename "$P")"
        AD="$(echo "$P" | sed -E "s#^.*(${ADAPTER_PATTERN}).*\$#\\1#")"
        if [ -n "$BN" ] && [ -n "$AD" ]; then
          echo "$BN|$AD" >> "$OUT/basename_to_adapter.txt"
        fi
      done
  sort -u -o "$OUT/basename_to_adapter.txt" "$OUT/basename_to_adapter.txt"

  # 6) Infer adapters by filenames
  grep -Eo '[A-Za-z0-9_-]+\.(swift|mm|m|h|hpp|cpp)' "$OUT/deprecations.txt" | sort -u > "$OUT/basenames.txt" || true
  if [ -s "$OUT/basenames.txt" ] && [ -s "$OUT/basename_to_adapter.txt" ]; then
    while IFS= read -r BN; do
      AD="$(grep -E "^${BN}\\|" "$OUT/basename_to_adapter.txt" | cut -d '|' -f2 | sort -u)"
      [ -n "$AD" ] && echo "$AD" >> "$OUT/adapters.txt"
    done < "$OUT/basenames.txt"
  fi

  sort -u -o "$OUT/adapters.txt" "$OUT/adapters.txt"
fi

sort -u -o "$OUT/adapters.txt" "$OUT/adapters.txt" 2>/dev/null || true

echo "Total deprecation lines: $(wc -l < "$OUT/deprecations.txt" 2>/dev/null || echo 0)"
echo "Adapters with deprecations:"
sed -E 's/^/- /' "$OUT/adapters.txt" || true
