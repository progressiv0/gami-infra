# Terraform — Hetzner VPS provisioning

Provisions the 3-node network + firewall + servers described in
`infrastructure-cicd-plan.md` Phase 5.

**Status: written, not yet validated.** There's no `terraform` binary in the
environment this was authored in, so this hasn't been through `terraform
validate`/`plan`/`apply`. Braces balance and resource references are
internally consistent on manual review, but treat this like an unreviewed
first-pass PR — read it carefully before pointing it at real infrastructure,
and definitely run `terraform plan` (never `apply` blind) the first time.

```bash
terraform init \
  -backend-config="access_key=$HETZNER_S3_ACCESS_KEY" \
  -backend-config="secret_key=$HETZNER_S3_SECRET_KEY"

TF_VAR_hcloud_token="..." \
TF_VAR_admin_ip_cidr="203.0.113.4/32" \
TF_VAR_ssh_public_key="$(cat ~/.ssh/id_ed25519.pub)" \
  terraform plan
```

Per the plan, `terraform apply` runs from a GitHub Actions `workflow_dispatch`
(gated, manual, audit-trailed) — not routinely from a laptop.
