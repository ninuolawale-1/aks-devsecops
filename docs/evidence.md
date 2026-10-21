# Evidence Log

All results below are from a live deployment on **October 21, 2026**. The environment was torn down afterward.

## Pipeline

| Check | Result | Link |
|---|---|---|
| Full pipeline (scan, build, sign, deploy) | All 7 jobs passed | [Run 39639666278](https://github.com/ninuolawale-1/aks-devsecops/actions/runs/39639666278) |
| SAST gate blocking a vulnerable change | SAST failed on gosec G704 (SSRF) after removing a `#nosec` exception | Closed test PR |

Screenshots: `images/01-pipeline-green.png`, `images/03-pipeline-blocked.png`

## Admission, network, and RBAC tests (`scripts/demo-attacks.sh`)

Result: **10/10 passed**

```
== 1. Admission control (Kyverno) ==
PASS  privileged container was rejected
PASS  Docker Hub image with :latest was rejected
PASS  unsigned image from our own ACR was rejected
PASS  hostNetwork pod was rejected

== 2. Network segmentation (default-deny NetworkPolicies) ==
PASS  labeled client reached the API
PASS  unlabeled pod was blocked (request timed out)

== 3. Least-privilege RBAC ==
PASS  app service account cannot: create pods -n kube-system
PASS  app service account cannot: get secrets -n kube-system
PASS  app service account cannot: create clusterrolebinding
PASS  app service account cannot: create deployments -n secure-app
```

Screenshot: `images/02-demo-attacks.png`

## Supply chain

| Item | Value |
|---|---|
| Signed image digest | `sha256:406c495168d71cc15000153baaa79923573db5c336f0cd55ea3090413e895213` |
| Built from commit | `a6a6e9a2f305a1832c97bc83c844e941d0c18497` |
| Signed by | `ninuolawale-1/aks-devsecops/.github/workflows/devsecops.yml@refs/heads/main` |
| Rekor transparency log index | `3359363649` |
| Running app version | `a6a6e9a` (matches the signed commit) |

Screenshot: `images/04-cosign-verify.png`

## Infrastructure

Deployed with Terraform to East US on a `Standard_D2as_v4` node. Azure resources are shown in `images/05-azure-resources.png`.

## CVE comparison (`scripts/compare-cves.sh`)

Run on October 21, 2026, with the Trivy vulnerability database as of that date.

| Image | Critical | High | All | Size | Packages |
|---|---|---|---|---|---|
| Baseline (full Go image, root) | 2 | 154 | 1,912 | 1,380 MB | 220 |
| Hardened (distroless, non-root) | 0 | 0 | 2 | 15 MB | 7 |

**Result:** 99.9% fewer CVEs, zero critical or high, and a 99% smaller image.

Screenshot: `images/06-cve-comparison.png`