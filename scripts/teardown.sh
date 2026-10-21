#!/usr/bin/env bash
# Destroy everything so the lab stops costing money. Re-create any time with
# `terraform apply` + scripts/bootstrap-cluster.sh (about 15 minutes).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
terraform -chdir="$ROOT/infra/terraform" destroy
