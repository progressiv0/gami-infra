variable "hcloud_token" {
  description = "Hetzner Cloud API token. Passed via TF_VAR_hcloud_token env var — never committed."
  type        = string
  sensitive   = true
}

variable "admin_ip_cidr" {
  description = "CIDR allowed to reach SSH (port 22) and the k3s API (port 6443) on each node. Set to your actual admin IP(s), not 0.0.0.0/0."
  type        = string
}

variable "location" {
  description = "Hetzner datacenter location."
  type        = string
  default     = "fsn1"
}

# Pre-existing Hetzner servers this repo attaches networking/firewalls to.
# Terraform never creates, resizes, or destroys these (see main.tf's `data
# "hcloud_server"` block) — both are already-provisioned cx22 boxes, one per
# environment, each running its own fully independent, unjoined k3s
# installation (no shared cluster, no etcd quorum to keep, no "differently
# sized nodes" — that framing belonged to the old 3-node shared-cluster
# design). Add a new entry here (name must match the real Hetzner server
# name exactly) to bring another already-provisioned box under this repo's
# network/firewall management — Terraform will never touch the server
# itself, only what's attached to it.
variable "nodes" {
  description = "One entry per pre-existing k3s server this repo manages networking/firewalls for: name (must match the real Hetzner server name) and which environment it belongs to."
  type = list(object({
    name = string
    env  = string
  }))
  default = [
    { name = "gami-staging", env = "staging" },
    { name = "gami-prod", env = "prod" },
  ]
}
