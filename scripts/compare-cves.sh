#!/usr/bin/env bash
# Before/after evidence for "hardened container images ... reducing CVEs".
# Builds the naive baseline image and the hardened distroless image, scans
# both with Trivy, and prints the numbers. Needs Docker + Trivy locally.
set -euo pipefail
cd "$(dirname "$0")/../app"

docker build -q -f Dockerfile.baseline -t secure-api:baseline . >/dev/null
docker build -q -f Dockerfile          -t secure-api:hardened . >/dev/null

count() { # image severity-list
  trivy image --quiet --format json --severity "$2" "$1" \
    | jq '[.Results[]?.Vulnerabilities[]?] | length'
}
size() { docker image inspect "$1" --format '{{.Size}}' | awk '{printf "%.0f MB", $1/1024/1024}'; }
pkgs() { trivy image --quiet --format json --list-all-pkgs "$1" | jq '[.Results[]?.Packages[]?] | length'; }

printf '%-10s %10s %10s %10s %8s %8s\n' IMAGE CRITICAL HIGH ALL SIZE PKGS
for t in baseline hardened; do
  img="secure-api:$t"
  printf '%-10s %10s %10s %10s %8s %8s\n' "$t" \
    "$(count $img CRITICAL)" "$(count $img HIGH)" \
    "$(count $img UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL)" "$(size $img)" "$(pkgs $img)"
done
echo
echo "Record these numbers (and the date) in docs/evidence.md."
