output "node_public_ips" {
  description = "Public IPv4 addresses of the 3 k3s nodes, keyed by node name."
  value       = { for name, s in hcloud_server.node : name => s.ipv4_address }
}

output "node_private_ips" {
  description = "Private network IPs, keyed by node name — used by Ansible's dynamic inventory and by nodes joining the k3s cluster over the private network."
  value       = { for name, s in hcloud_server.node : name => s.network[0].ip }
}

output "node_names" {
  value = keys(hcloud_server.node)
}

output "node_envs" {
  description = "Node name -> env label (dev/staging/prod) mapping, matching var.nodes."
  value       = { for name, s in hcloud_server.node : name => s.labels.env }
}
