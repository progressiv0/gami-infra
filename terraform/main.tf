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
  count       = var.node_count
  name        = "gami-node-${count.index + 1}"
  server_type = var.server_type
  image       = "ubuntu-24.04"
  location    = var.location
  ssh_keys    = [hcloud_ssh_key.ops.id]
  firewall_ids = [hcloud_firewall.gami.id]

  network {
    network_id = hcloud_network.gami.id
  }

  # Ansible's dynamic hcloud inventory (ansible/inventory/hcloud.yml) groups
  # nodes by this label rather than by hardcoded IPs.
  labels = {
    role = "k3s-server"
  }

  depends_on = [hcloud_network_subnet.gami]
}
