# Read-only lookups against servers that already exist — Terraform never
# creates, resizes, or destroys them. Everything below only attaches
# networking/firewalls to whatever these resolve to.
data "hcloud_server" "node" {
  for_each = { for n in var.nodes : n.name => n }
  name     = each.value.name
}

# Small dedicated network — its only purpose is letting staging's central
# ArgoCD instance reach prod's k3s API (port 6443) to manage it as a
# registered remote cluster (see ansible/roles/argocd/tasks/
# register-remote-cluster.yml). Nothing else needs node-to-node
# connectivity: each node runs its own fully independent, unjoined k3s
# installation (no etcd peers, no Flannel VXLAN between them), so there's
# no general shared private network anymore.
resource "hcloud_network" "argocd_link" {
  name     = "gami-argocd-link"
  ip_range = "10.10.0.0/24"
}

resource "hcloud_network_subnet" "argocd_link" {
  network_id   = hcloud_network.argocd_link.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = "10.10.0.0/24"
}

# Pinned static IPs so the address ArgoCD's remote-cluster registration
# Secret points at is deterministic rather than depending on reading it
# back after apply. staging=.2, prod=.3.
resource "hcloud_server_network" "argocd_link" {
  for_each   = data.hcloud_server.node
  server_id  = each.value.id
  network_id = hcloud_network.argocd_link.id
  ip         = each.key == "gami-staging" ? "10.10.0.2" : "10.10.0.3"

  depends_on = [hcloud_network_subnet.argocd_link]
}

resource "hcloud_firewall" "gami" {
  name = "gami-firewall"

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = [var.admin_ip_cidr]
  }

  # k3s API — admin access only. There's no longer a shared private network
  # of trusted cluster peers to scope this to instead (each node is its own
  # independent cluster now) — kubectl access should come from your admin
  # IP(s)/VPN, the same source as SSH.
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "6443"
    source_ips = [var.admin_ip_cidr]
  }

  # HTTP/HTTPS — Traefik ingress, public.
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "80"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # No etcd (2379-2380) or Flannel VXLAN (8472/udp) rules — nothing joins
  # anymore, so there's no node-to-node cluster traffic to permit.
}

resource "hcloud_firewall_attachment" "gami" {
  firewall_id = hcloud_firewall.gami.id
  server_ids  = [for s in data.hcloud_server.node : s.id]
}

# The one deliberate hole that lets staging's ArgoCD reach prod's k3s API
# over the dedicated argocd_link network — nothing else is allowed on it.
resource "hcloud_firewall" "argocd_link" {
  name = "gami-argocd-link-firewall"

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "6443"
    source_ips = [hcloud_network_subnet.argocd_link.ip_range]
  }
}

resource "hcloud_firewall_attachment" "argocd_link" {
  firewall_id = hcloud_firewall.argocd_link.id
  server_ids  = [data.hcloud_server.node["gami-prod"].id]
}
