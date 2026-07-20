resource "hcloud_ssh_key" "ops" {
  name       = "gami-ops"
  public_key = var.ssh_public_key
}

resource "hcloud_network" "gami" {
  name     = "gami-private"
  ip_range = "10.0.0.0/16"
}

resource "hcloud_network_subnet" "gami" {
  network_id   = hcloud_network.gami.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = "10.0.1.0/24"
}

resource "hcloud_firewall" "gami" {
  name = "gami-firewall"

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = [var.admin_ip_cidr]
  }

  # k3s API server — restricted to the private network (nodes joining/
  # talking to each other), not the public internet. Admin kubectl access
  # should go over a VPN/bastion onto the private network, not this rule.
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "6443"
    source_ips = [hcloud_network.gami.ip_range]
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

  # Embedded etcd + Flannel VXLAN — node-to-node only, private network.
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "2379-2380"
    source_ips = [hcloud_network.gami.ip_range]
  }
  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "8472"
    source_ips = [hcloud_network.gami.ip_range]
  }
}

resource "hcloud_server" "node" {
  for_each    = { for n in var.nodes : n.name => n }
  name        = each.value.name
  server_type = each.value.server_type
  image       = "ubuntu-24.04"
  location    = var.location
  ssh_keys    = [hcloud_ssh_key.ops.id]
  firewall_ids = [hcloud_firewall.gami.id]

  network {
    network_id = hcloud_network.gami.id
  }

  labels = {
    # Ansible's dynamic hcloud inventory (ansible/inventory/hcloud.yml)
    # groups nodes by this label rather than by hardcoded IPs — all 3 run
    # the k3s server role regardless of which environment they're "home" to.
    role = "k3s-server"
    # Consumed by Ansible (node-baseline / k3s-server roles, applied as a
    # Kubernetes node label post-join) and referenced directly by
    # nodeAffinity in base/*/deployment.yaml + overlays' postgres-cluster
    # resources — see README.md's "Node topology" section.
    env = each.value.env
  }

  depends_on = [hcloud_network_subnet.gami]
}
