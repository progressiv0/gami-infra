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

variable "node_count" {
  description = "Number of k3s server nodes — 3 for the HA embedded-etcd quorum this plan assumes. Changing this changes the etcd quorum math (Phase 5's Ansible notes)."
  type        = number
  default     = 3
}

variable "server_type" {
  description = "Hetzner server type for each node."
  type        = string
  default     = "cx32"
}

variable "location" {
  description = "Hetzner datacenter location."
  type        = string
  default     = "fsn1"
}
