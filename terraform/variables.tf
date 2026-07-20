variable "hcloud_token" {
  description = "Hetzner Cloud API token. Passed via TF_VAR_hcloud_token env var — never committed."
  type        = string
  sensitive   = true
}

variable "admin_ip_cidr" {
  description = "CIDR allowed to reach SSH (port 22) and the k3s API (port 6443) on each node. Set to your actual admin IP(s), not 0.0.0.0/0."
  type        = string
}

variable "ssh_public_key" {
  description = "Public key content (e.g. contents of ~/.ssh/id_ed25519.pub) installed on all 3 nodes for the ops user."
  type        = string
}

variable "location" {
  description = "Hetzner datacenter location."
  type        = string
  default     = "fsn1"
}

# 3 nodes, deliberately sized differently and pinned to one primary
# environment each — see README.md's "Node topology" section:
#   - dev/staging nodes are small and normally only run their own
#     environment (ArgoCD lives on the dev node too).
#   - the prod node is bigger, but prod's own Deployments are spread across
#     all 3 nodes (pod anti-affinity in base/), not confined to this node —
#     this list only controls where each node's OWN environment prefers to
#     live and how big that node is, not where prod can schedule.
# Changing the *number* of nodes (not just their names/sizes) changes the
# etcd quorum math (odd member count needed) — see Phase 5's Ansible notes
# in .claude/plans/infrastructure-cicd-plan.md.
variable "nodes" {
  description = "One entry per k3s server node: name, size, and which environment it's the home node for (env label, used by Kubernetes nodeAffinity in base/overlays)."
  type = list(object({
    name        = string
    server_type = string
    env         = string
  }))
  default = [
    { name = "gami-node-dev",     server_type = "cx22", env = "dev" },
    { name = "gami-node-staging", server_type = "cx22", env = "staging" },
    { name = "gami-node-prod",    server_type = "cx42", env = "prod" },
  ]
}
