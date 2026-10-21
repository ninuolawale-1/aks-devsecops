#!/usr/bin/env bash
# Proves the controls work against the LIVE cluster. Run after the pipeline has
# deployed at least once. Screenshot or record the output; it's your evidence.
#
# Each test prints PASS when the cluster does the secure thing.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ACR="$(terraform -chdir="$ROOT/infra/terraform" output -raw acr_name)"
ACR_SERVER="$(terraform -chdir="$ROOT/infra/terraform" output -raw acr_login_server)"
NS=secure-app
SIGNED_IMAGE="$(kubectl -n $NS get deploy secure-api -o jsonpath='{.spec.template.spec.containers[0].image}')"
OUT="$(mktemp -d)"

pass() { printf '\033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '\033[31mFAIL\033[0m  %s\n' "$1"; }

# Applies a manifest and expects Kyverno to reject it.
expect_denied() {
  local name="$1" file="$2"
  if kubectl apply -f "$file" >"$OUT/$name.log" 2>&1; then
    fail "$name was ADMITTED"; kubectl delete -f "$file" --ignore-not-found >/dev/null 2>&1
  else
    pass "$name was rejected"; grep -m1 -oE '(policy|validation error).*' "$OUT/$name.log" | sed 's/^/        /'
  fi
}

# A hardened pod template; each test breaks exactly one thing.
pod() { # name image extra_container_yaml extra_spec_yaml labels
cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $1
  namespace: $NS
  labels: { ${5:-test: "true"} }
spec:
  automountServiceAccountToken: false
  securityContext: { runAsNonRoot: true, runAsUser: 65532, seccompProfile: { type: RuntimeDefault } }
  restartPolicy: Never
${4:-}
  containers:
    - name: c
      image: $2
${6:-}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: ["ALL"] }
${3:-}
      resources:
        requests: { cpu: 10m, memory: 16Mi }
        limits: { cpu: 100m, memory: 32Mi }
EOF
}

echo "== 1. Admission control (Kyverno) =="

pod privileged "$SIGNED_IMAGE" "        privileged: true" > "$OUT/priv.yaml"
expect_denied "privileged container" "$OUT/priv.yaml"

pod dockerhub "nginx:latest" > "$OUT/hub.yaml"
expect_denied "Docker Hub image with :latest" "$OUT/hub.yaml"

echo "   (importing an UNSIGNED image into your ACR...)"
az acr import --name "$ACR" --source mcr.microsoft.com/azuredocs/aks-helloworld:v1 \
  --image unsigned/helloworld:v1 --force >/dev/null 2>&1
pod unsigned "$ACR_SERVER/unsigned/helloworld:v1" > "$OUT/unsigned.yaml"
expect_denied "unsigned image from our own ACR" "$OUT/unsigned.yaml"

pod hostnet "$SIGNED_IMAGE" "" "  hostNetwork: true" > "$OUT/hostnet.yaml"
expect_denied "hostNetwork pod" "$OUT/hostnet.yaml"

echo
echo "== 2. Network segmentation (default-deny NetworkPolicies) =="
URL="http://secure-api.$NS.svc.cluster.local/healthz"
ARGS="      args: [\"probe\", \"$URL\"]"

pod allowed-client "$SIGNED_IMAGE" "" "" 'access: secure-api' "$ARGS" > "$OUT/allowed.yaml"
pod random-pod "$SIGNED_IMAGE" "" "" 'test: "true"' "$ARGS" > "$OUT/denied.yaml"
kubectl apply -f "$OUT/allowed.yaml" -f "$OUT/denied.yaml" >/dev/null

for p in allowed-client random-pod; do
  kubectl -n $NS wait --for=jsonpath='{.status.phase}'=Succeeded pod/$p --timeout=30s >/dev/null 2>&1 \
    || kubectl -n $NS wait --for=jsonpath='{.status.phase}'=Failed pod/$p --timeout=30s >/dev/null 2>&1
done
A="$(kubectl -n $NS logs allowed-client 2>/dev/null)"
D="$(kubectl -n $NS logs random-pod 2>/dev/null)"
[[ "$A" == REACHABLE* ]] && pass "labeled client reached the API  -> $A" || fail "labeled client could not reach the API -> $A"
[[ "$D" == BLOCKED* ]]  && pass "unlabeled pod was blocked       -> $D" || fail "unlabeled pod reached the API -> $D"
kubectl -n $NS delete pod allowed-client random-pod --ignore-not-found >/dev/null

echo
echo "== 3. Least-privilege RBAC =="
for check in "create pods -n kube-system" "get secrets -n kube-system" "create clusterrolebinding" "create deployments -n $NS"; do
  r="$(kubectl auth can-i $check --as=system:serviceaccount:$NS:secure-api 2>/dev/null)"
  [[ "$r" == "no" ]] && pass "app service account cannot: $check" || fail "app service account CAN: $check"
done
echo
echo "Logs in $OUT"
