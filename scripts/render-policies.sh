#!/usr/bin/env bash
# Fill placeholders in Kyverno policies + tests and write them to an output dir.
# Usage: scripts/render-policies.sh <acr_login_server> <github_owner> <github_repo> [out_dir]
set -euo pipefail

ACR="${1:?acr login server, e.g. acrdevsecopsab12c.azurecr.io}"
OWNER="${2:?github owner}"
REPO="${3:?github repo}"
OUT="${4:-build/policies}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
rm -rf "$OUT"
mkdir -p "$OUT"
cp -r "$ROOT/policies/." "$OUT/"

# Write to a temp file and move it back: works with both GNU sed (Linux/CI)
# and BSD sed (macOS), which disagree on `sed -i` syntax.
find "$OUT" -type f -name '*.yaml' | while IFS= read -r f; do
  sed -e "s|__ACR_LOGIN_SERVER__|${ACR}|g" \
      -e "s|__GITHUB_OWNER__|${OWNER}|g" \
      -e "s|__GITHUB_REPO__|${REPO}|g" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done

echo "Rendered policies to $OUT"
