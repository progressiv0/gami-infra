output "node_public_ips" {
  description = "Public IPv4 addresses of the 3 k3s nodes."
  value       = hcloud_server.node[*].ipv4_address
}

output "node_private_ips" {
  description = "Private network IPs — used by Ansible's dynamic inventory and by nodes joining the k3s cluster over the private network."
  value       = [for s in hcloud_server.node : s.network[0].ip]
}

output "node_names" {
  value = hcloud_server.node[*].name
}
