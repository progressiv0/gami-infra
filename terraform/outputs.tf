output "node_public_ips" {
  description = "Public IPv4 addresses of the 2 k3s nodes (staging, prod), keyed by node name."
  value       = { for name, s in data.hcloud_server.node : name => s.ipv4_address }
}

output "node_argocd_link_ips" {
  description = "Addresses on the dedicated argocd-link private network, keyed by node name. Prod's entry is what Ansible feeds into the ArgoCD remote-cluster registration Secret's server: field (see ansible/roles/argocd/tasks/register-remote-cluster.yml); staging's is unused today but kept for symmetry."
  value       = { for name, s in hcloud_server_network.argocd_link : name => s.ip }
}

output "node_names" {
  value = keys(data.hcloud_server.node)
}

output "node_envs" {
  description = "Node name -> env label (staging/prod) mapping, matching var.nodes."
  value       = { for n in var.nodes : n.name => n.env }
}
