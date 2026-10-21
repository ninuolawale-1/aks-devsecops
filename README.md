# DevSecOps Pipeline – Secure Container Deployment to AKS

A GitHub Actions pipeline that scans code, dependencies, infrastructure, and container images, blocks on high/critical findings, signs what it builds, and deploys only signed, hardened workloads into an AKS cluster that enforces its own guardrails.

```
 push / PR
    │
    ├─ Unit tests ─────────────┐
    ├─ SAST (gosec, Semgrep) ──┤
    ├─ Deps + secrets (govulncheck, Trivy fs) ─┤   any HIGH/CRITICAL ⇒ stop
    ├─ IaC (Trivy config: Terraform + K8s) ────┤
    └─ Kyverno policy unit tests ──────────────┘
                     │
             Build distroless image
                     │
             Trivy image scan ──────── HIGH/CRITICAL (fixable) ⇒ stop
                     │
             CycloneDX SBOM (Syft)
                     │            ── main branch only below ──
             Push to ACR (OIDC, no secrets)
                     │
             cosign sign + attest SBOM (keyless, Sigstore)
                     │
             cosign verify ── [production environment gate]
                     │
             kubectl apply (pinned digest, namespace-scoped identity)
                     │
     ┌───────────────▼──────────────────────────────────────┐
     │ AKS                                                  │
     │  Kyverno: reject unsigned / no-SBOM / privileged /   │
     │           root / hostNetwork / :latest / foreign reg │
     │  PSA restricted on the namespace (second layer)      │
     │  Default-deny NetworkPolicies (Cilium)               │
     │  Entra ID auth only, Azure RBAC, app SA has nothing  │
     └──────────────────────────────────────────────────────┘
```

## Repo layout

| Path | What it is |
|---|---|
| `app/` | Small Go API, its tests, the hardened `Dockerfile`, and `Dockerfile.baseline` (the "before" image, never deployed) |
| `infra/terraform/` | Resource group, ACR, AKS, Log Analytics, GitHub OIDC identity, Kyverno identity, all role assignments |
| `.github/workflows/devsecops.yml` | The pipeline |
| `policies/kyverno/` | Admission policies (signature + SBOM verification, pod hardening, image rules) |
| `policies/tests/` | `kyverno test` suite: one good Deployment, one bad Deployment per rule |
| `k8s/platform/` | Namespace with PSA, NetworkPolicies, RBAC (applied by you, the admin) |
| `k8s/app/` | Deployment + Service (applied by the pipeline) |
| `k8s/kyverno-values.yaml` | Helm values wiring Kyverno to ACR through Workload Identity |
| `scripts/` | Bootstrap, attack demo, CVE comparison, teardown |
| `.trivyignore.yaml` | Risk acceptances, each with a reason and an expiry date |

What's already been verified before you start: the Go tests pass, gosec reports 0 high-severity issues, the Trivy IaC scan passes with the one documented exception, all 13 Kyverno policy tests pass on Kyverno v1.19.2, the real Deployment passes every policy, and actionlint is clean. What hasn't been run yet is anything that needs your Azure subscription.

---

## Cost (read this first)

Rough lab cost while the cluster exists: one `Standard_B2ms` node (~$60/month if left on 24/7), AKS Free tier control plane ($0), ACR Basic (~$5/month), and Log Analytics ingestion (a few dollars at lab volume). Check current Azure pricing for your region. The pattern that keeps this cheap is simple: build it, capture your evidence, run `scripts/teardown.sh`, and recreate it when you need it again. A full rebuild takes about 15 minutes.

## Prerequisites

• Azure subscription where you're Owner (or Contributor + User Access Administrator; Terraform creates role assignments)
• Azure CLI, Terraform ≥ 1.6, kubectl, kubelogin (`az aks install-cli` installs both), Helm 3
• A GitHub repo (public is easiest; code scanning SARIF upload needs public or GitHub Advanced Security)
• Optional for local work: Go 1.24, Docker, Trivy, Kyverno CLI

---

## Phase 0 – Run it locally (free, ~30 min)

Get familiar with each piece before paying for anything.

```bash
cd app && go test ./... && cd ..

# Policy tests
scripts/render-policies.sh example.azurecr.io you aks-devsecops build/policies
kyverno test build/policies/tests

# IaC scan exactly as CI runs it
trivy config --severity HIGH,CRITICAL --ignorefile .trivyignore.yaml \
  --skip-dirs policies/tests --skip-files app/Dockerfile.baseline .

# Before/after CVE numbers (needs Docker)
scripts/compare-cves.sh
```

Save the `compare-cves.sh` table. Those numbers replace "reducing CVEs" on your resume with something concrete.

## Phase 1 – Provision Azure with Terraform (~15 min)

```bash
az login
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars   # fill in subscription, GitHub owner/repo
terraform init
terraform plan
terraform apply
terraform output
```

Read `main.tf` and `github_oidc.tf` while it runs. The design decisions worth being able to explain:

• `local_account_disabled = true`: there's no static admin kubeconfig to leak; everyone authenticates through Entra ID.
• The pipeline identity gets `AcrPush` on one registry and `RBAC Writer` on one namespace. It cannot touch `kube-system`, Kyverno, or RBAC objects, so a compromised pipeline can't switch the guardrails off.
• Federated credentials trust only `main` and the `production` environment of your repo. A fork or feature branch can't get an Azure token.
• Kyverno gets its own pull-only identity via Workload Identity, so no registry password lives in the cluster.

## Phase 2 – Wire up GitHub (~10 min)

1. Push this repo to GitHub as `<you>/aks-devsecops`. Replace `YOUR_GH_USER` in `app/go.mod`.
2. **Settings → Secrets and variables → Actions → Variables** (variables, not secrets; nothing here is sensitive, which is the whole point of OIDC):

   | Variable | Value |
   |---|---|
   | `AZURE_CLIENT_ID` | `terraform output -raw AZURE_CLIENT_ID` |
   | `AZURE_TENANT_ID` | `terraform output -raw AZURE_TENANT_ID` |
   | `AZURE_SUBSCRIPTION_ID` | your subscription ID |
   | `ACR_NAME` | `terraform output -raw acr_name` |
   | `AKS_NAME` | `terraform output -raw aks_name` |
   | `AKS_RESOURCE_GROUP` | `terraform output -raw resource_group` |

3. **Settings → Environments → New environment → `production`**. Add yourself as a required reviewer. Now every deploy waits for an approval click, which is a real change-control gate.
4. **Settings → Branches**: protect `main`, require PRs and require the scan jobs to pass.

## Phase 3 – Bootstrap the cluster (~10 min)

```bash
scripts/bootstrap-cluster.sh <github_owner> aks-devsecops
```

This installs Kyverno, applies the policies, and lays down the namespace, NetworkPolicies, and RBAC. Run `kubectl get clusterpolicy` and confirm all three show `READY: True`.

## Phase 4 – First pipeline run

Open a PR with any small change. Every scan runs, nothing touches Azure. Merge it. On `main`, the build job pushes, signs, and attests; the deploy job waits for your approval, verifies the signature, and deploys by digest.

```bash
kubectl -n secure-app get pods
kubectl -n secure-app port-forward svc/secure-api 8080:80   # then curl localhost:8080
```

## Phase 5 – Prove it works (this is the part interviewers care about)

**Live attack demo:**

```bash
scripts/demo-attacks.sh
```

It tries a privileged pod, a Docker Hub `:latest` image, an unsigned image imported into your own ACR, and a hostNetwork pod (all should be rejected). It then checks that a labeled client reaches the API while an unlabeled pod gets blocked, and that the app's service account can't do anything. Every line should say PASS. Screenshot it.

**Break the pipeline on purpose** (one PR each, then close it). Each failed run is a screenshot:

| Change | Expected job to fail |
|---|---|
| Commit a fake AWS-format access key (`AKIA` + 16 characters) in any file | Dependency + secret scan (Trivy secret) |
| Replace the final stage with `FROM golang:1.20` (old Go + old Debian) | Trivy image scan |
| Remove the `#nosec` comment in `main.go` | SAST (gosec G704) |
| Set `privileged: true` in `k8s/app/deployment.yaml` | IaC scan (KSV-0017), and Kyverno would reject it anyway |
| Delete the AZU-0041 entry in `.trivyignore.yaml` | IaC scan (AZU-0041) |

**Supply chain inspection:**

```bash
IMG=$(kubectl -n secure-app get deploy secure-api -o jsonpath='{.spec.template.spec.containers[0].image}')
cosign verify $IMG \
  --certificate-identity "https://github.com/<you>/aks-devsecops/.github/workflows/devsecops.yml@refs/heads/main" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com | jq
cosign download attestation $IMG | jq -r .payload | base64 -d | jq '.predicate.components | length'
```

The second command counts the components in the signed SBOM, so you can show exactly what's inside the running image.

Record what you capture in `docs/evidence.md`.

## Phase 6 – Tear down

```bash
scripts/teardown.sh
```

---

## Troubleshooting

• **Kyverno rejects your own signed image with an auth or "no signatures found" error.** This is the most likely snag. Check that the Kyverno admission pod has the label `azure.workload.identity/use=true` and the SA annotation with the Kyverno client ID: `kubectl -n kyverno get pod -l app.kubernetes.io/component=admission-controller -o yaml | grep -i azure`. Confirm the federated credential subject is `system:serviceaccount:kyverno:kyverno-admission-controller`. Role assignments can take a few minutes to propagate.
• **cosign version mismatch.** The pipeline pins cosign v2.6.1 on purpose. Cosign v3 stores signatures as OCI 1.1 referrers by default, which Kyverno's `ClusterPolicy` image verification doesn't read. If you upgrade, move the verification policy to Kyverno's `ImageValidatingPolicy` at the same time.
• **`az aks get-credentials` works but kubectl says Forbidden.** You forgot `kubelogin convert-kubeconfig -l azurecli`, or your Azure role assignment hasn't propagated yet (wait 2–5 minutes).
• **Azure login fails in Actions with "no matching federated identity".** The job's subject doesn't match. Build jobs must run on `main`; the deploy job must use `environment: production`. Owner and repo names are case-sensitive.
• **Pods stuck Pending.** One B2ms is tight with Kyverno and Container Insights. Set `node_count = 2` and re-apply.

## Known gaps / next steps (good interview material)

• Kyverno v1.19 marks `kyverno.io/v1 ClusterPolicy` as deprecated in favor of CEL-based `ValidatingPolicy` and `ImageValidatingPolicy`. They still work; migrating them is a solid follow-up.
• The API server is public (documented exception AZU-0041). The real fix is a private cluster plus a self-hosted runner inside the VNet.
• Add Microsoft Defender for Containers for runtime threat detection; Kyverno only covers admission time.
• Pin base images by digest and let Dependabot bump action SHAs and image digests.

## Talking points

• **Why keyless signing?** No signing key to store, rotate, or leak. The signature is bound to the workflow's OIDC identity and recorded in Rekor, so you can prove *which workflow on which branch* built the image.
• **Why verify in both the pipeline and the cluster?** The pipeline check catches problems early; the cluster check catches anything that bypasses the pipeline (someone with kubectl, a compromised token). Defense in depth.
• **Why deploy by digest?** Tags are mutable. A digest guarantees the cluster runs the exact bytes that were scanned and signed.
• **Why `ignore-unfixed` on the image scan?** Blocking on a CVE with no available patch stops every deploy without making anything safer. Unfixed findings still appear in the report; they just don't gate.
• **Why separate platform and app manifests?** Separation of duties. The pipeline ships the app; only an admin can change the guardrails.
