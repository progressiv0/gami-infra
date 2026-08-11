# Terraform — Hetzner networking for pre-existing servers

Attaches networking and firewalls to the two already-provisioned Hetzner
servers (`gami-staging`, `gami-prod` — see `variables.tf`'s `nodes` list)
that each run their own fully independent, unjoined k3s installation.
**This does not create, resize, or destroy the servers themselves** — they
already exist; Terraform only manages what's attached to them (a dedicated
private network so staging's ArgoCD can reach prod's k3s API, and per-node
firewalls). A `terraform plan` that ever proposes creating or destroying a
server means something's misconfigured (e.g. a `nodes` entry whose `name`
doesn't match the real Hetzner server name) — stop and investigate before
applying.

**Status: written, not yet validated against real infra.** There's no
`terraform` binary in the environment this was authored in, so this hasn't
been through `terraform validate`/`plan`/`apply`. Braces balance and
resource references are internally consistent on manual review, but treat
this like an unreviewed first-pass PR — read it carefully before pointing
it at real infrastructure, and definitely run `terraform plan` (never
`apply` blind) the first time.

All required credentials are environment variables, never committed — see
`.env.example` at the repo root for the full list (`TF_VAR_hcloud_token`,
`TF_VAR_admin_ip_cidr`, `HETZNER_S3_ACCESS_KEY`, `HETZNER_S3_SECRET_KEY`).
Copy it to `.env`, fill in real values, `set -a; source .env; set +a`,
then:

```bash
terraform init \
  -backend-config="access_key=$HETZNER_S3_ACCESS_KEY" \
  -backend-config="secret_key=$HETZNER_S3_SECRET_KEY"

terraform plan
```

Per the plan, `terraform apply` runs from a GitHub Actions `workflow_dispatch`
(gated, manual, audit-trailed) — not routinely from a laptop.
