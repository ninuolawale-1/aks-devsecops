variable "subscription_id" {
  description = "Azure subscription to deploy into."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "eastus"
}

variable "prefix" {
  description = "Short name used in resource names (lowercase letters and numbers)."
  type        = string
  default     = "devsecops"

  validation {
    condition     = can(regex("^[a-z0-9]{3,12}$", var.prefix))
    error_message = "prefix must be 3-12 lowercase letters/numbers."
  }
}

variable "github_owner" {
  description = "GitHub user or org that owns the repo (e.g. ninuolawale)."
  type        = string
}

variable "github_repo" {
  description = "GitHub repo name (e.g. aks-devsecops)."
  type        = string
}

variable "app_namespace" {
  description = "Kubernetes namespace the pipeline is allowed to deploy into."
  type        = string
  default     = "secure-app"
}

variable "node_vm_size" {
  description = "Node size. B2ms (2 vCPU / 8 GiB) is the cheapest size that comfortably runs Kyverno + the app."
  type        = string
  default     = "Standard_B2ms"
}

variable "node_count" {
  description = "Number of nodes in the default pool."
  type        = number
  default     = 1
}

variable "api_authorized_ip_ranges" {
  description = <<-EOT
    CIDRs allowed to reach the Kubernetes API server. Leave empty if you deploy
    from GitHub-hosted runners (their IPs aren't a small fixed set). Set it to
    ["<your-ip>/32"] if you only run kubectl from your own machine.
  EOT
  type        = list(string)
  default     = []
}

variable "tags" {
  type = map(string)
  default = {
    project = "aks-devsecops"
    owner   = "ninu"
    env     = "lab"
  }
}
