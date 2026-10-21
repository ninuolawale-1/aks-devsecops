#!/usr/bin/env bash
# One-time cluster setup, run by YOU (cluster admin), not by the pipeline.
#   1. connect kubectl through Entra ID
#   2. install Kyverno with Workload Identity for ACR access
#   3. apply Kyverno policies
#   4. apply platform guardrails (namespace + PSA, NetworkPolicies, RBAC)
#
# Usage: scripts/bootstrap-cluster.sh <github_owner> <github_repo> [auditor_group_object_id]
set -euo pipefail

OWNER="${1:?github owner}"
REPO="${2:?github repo}"
AUDITOR_GROUP="${3:-00000000-0000-0000-0000-000000000000}"
KYVERNO_CHART_VERSION="3.9.2"   # = Kyverno v1.19.2

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF="$ROOT/infra/terraform"
BUILD="$ROOT/build"
mkdir -p "$BUILD"

tfout() { terraform -chdir="$TF" output -raw "$1"; }
RG="$(tfout resource_group)"
AKS="$(tfout aks_name)"
ACR_SERVER="$(tfout acr_login_server)"
KYVERNO_CLIENT_ID="$(tfout kyverno_client_id)"

echo ">> Connecting to $AKS (Entra ID auth, local accounts are disabled)"
az aks get-credentials -g "$RG" -n "$AKS" --overwrite-existing
kubelogin convert-kubeconfig -l azurecli
kubectl get nodes

echo ">> Installing Kyverno $KYVERNO_CHART_VERSION"
sed "s|__KYVERNO_CLIENT_ID__|${KYVERNO_CLIENT_ID}|" "$ROOT/k8s/kyverno-values.yaml" > "$BUILD/kyverno-values.yaml"
helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
helm repo update kyverno >/dev/null
helm upgrade --install kyverno kyverno/kyverno \
  --namespace kyverno --create-namespace \
  --version "$KYVERNO_CHART_VERSION" \
  -f "$BUILD/kyverno-values.yaml" --wait --timeout 10m

echo ">> Applying Kyverno policies"
"$ROOT/scripts/render-policies.sh" "$ACR_SERVER" "$OWNER" "$REPO" "$BUILD/policies"
kubectl apply -f "$BUILD/policies/kyverno/"
kubectl wait --for=condition=Ready clusterpolicy --all --timeout=120s

echo ">> Applying platform guardrails"
mkdir -p "$BUILD/platform"
cp "$ROOT"/k8s/platform/*.yaml "$BUILD/platform/"
sed "s|__AUDITOR_GROUP_OBJECT_ID__|${AUDITOR_GROUP}|" "$ROOT/k8s/platform/rbac.yaml" > "$BUILD/platform/rbac.yaml"
kubectl apply -k "$BUILD/platform"

echo
kubectl get clusterpolicy
kubectl -n secure-app get networkpolicy
echo
echo "Done. Push to main and the pipeline will deploy into secure-app."
