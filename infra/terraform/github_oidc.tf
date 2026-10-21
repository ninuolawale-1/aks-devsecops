# ---------------------------------------------------------------------------
# GitHub Actions -> Azure with OIDC (no client secrets stored in GitHub).
#
# GitHub mints a short-lived token per job. Azure trusts it only when the
# token's subject matches one of the federated credentials below, so a fork,
# a feature branch, or a different repo can't assume this identity.
# ---------------------------------------------------------------------------
resource "azurerm_user_assigned_identity" "github" {
  name                = "id-${var.prefix}-github"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = var.tags
}

# Jobs running on the main branch (build, scan, push, sign).
resource "azurerm_federated_identity_credential" "main_branch" {
  name                = "github-main"
  resource_group_name = azurerm_resource_group.rg.name
  parent_id           = azurerm_user_assigned_identity.github.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = "https://token.actions.githubusercontent.com"
  subject             = "repo:${var.github_owner}@299236858/${var.github_repo}@1427938295:ref:refs/heads/main"
}

# Jobs that use the "production" GitHub environment (the deploy job).
# Add required reviewers on that environment in GitHub for a manual gate.
resource "azurerm_federated_identity_credential" "production_env" {
  name                = "github-production"
  resource_group_name = azurerm_resource_group.rg.name
  parent_id           = azurerm_user_assigned_identity.github.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = "https://token.actions.githubusercontent.com"
  subject             = "repo:${var.github_owner}@299236858/${var.github_repo}@1427938295:environment:production"
}

# --- Least-privilege grants for the pipeline identity ----------------------

# Push images to this one registry. Nothing else in the subscription.
resource "azurerm_role_assignment" "github_acr_push" {
  scope                = azurerm_container_registry.acr.id
  role_definition_name = "AcrPush"
  principal_id         = azurerm_user_assigned_identity.github.principal_id
}

# Allowed to download a kubeconfig (still has no Kubernetes permissions by itself).
resource "azurerm_role_assignment" "github_aks_user" {
  scope                = azurerm_kubernetes_cluster.aks.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = azurerm_user_assigned_identity.github.principal_id
}

# Read/write workloads in ONE namespace only. Cannot touch kube-system,
# Kyverno, cluster-scoped objects, Roles, or RoleBindings.
resource "azurerm_role_assignment" "github_ns_writer" {
  scope                = "${azurerm_kubernetes_cluster.aks.id}/namespaces/${var.app_namespace}"
  role_definition_name = "Azure Kubernetes Service RBAC Writer"
  principal_id         = azurerm_user_assigned_identity.github.principal_id
}

# ---------------------------------------------------------------------------
# Kyverno needs to READ signatures and attestations from the private ACR to
# verify them at admission time. It gets its own identity via AKS Workload
# Identity: pull-only on this registry, bound to Kyverno's service account.
# ---------------------------------------------------------------------------
resource "azurerm_user_assigned_identity" "kyverno" {
  name                = "id-${var.prefix}-kyverno"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "kyverno" {
  name                = "kyverno-admission-controller"
  resource_group_name = azurerm_resource_group.rg.name
  parent_id           = azurerm_user_assigned_identity.kyverno.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.aks.oidc_issuer_url
  subject             = "system:serviceaccount:kyverno:kyverno-admission-controller"
}

resource "azurerm_role_assignment" "kyverno_acr_pull" {
  scope                = azurerm_container_registry.acr.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.kyverno.principal_id
}
