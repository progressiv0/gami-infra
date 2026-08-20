# Terraform

Attaches networking and firewalls to the two already-provisioned Hetzner
servers (`gami-staging`, `gami-prod`), each running its own independent k3s
cluster.

**This does not create, resize, or destroy the servers themselves.** They
already exist; `main.tf` reads them with `data "hcloud_server"` lookups. A
`terraform plan` that ever proposes creating or destroying a server means
something is misconfigured — most likely a `nodes` entry in `variables.tf`
whose `name` doesn't match the real Hetzner server name. Stop and fix that
before applying.

---

## What it manages

- **`gami-argocd-link`** — a dedicated private network (`10.10.0.0/24`) with
  staging pinned to `10.10.0.2` and prod to `10.10.0.3`. It exists solely so
  staging's ArgoCD can reach prod's k3s API on 6443. There is no general
  shared network between the nodes; nothing joins anything.
- **Main firewall** — SSH (22) and the k3s API (6443) restricted to
  `admin_ip_cidr`, never `0.0.0.0/0`. HTTP/HTTPS (80/443) public — that's
  Traefik ingress, and the only genuinely public ports.
- **argocd-link firewall** — opens 6443 to the `10.10.0.0/24` subnet only,
  attached only to prod.
- **ArgoCD UI firewall** — opens NodePort 30443 to `admin_ip_cidr`, attached
  only to staging.

There are no etcd or Flannel VXLAN rules — nothing joins, so there's no
node-to-node cluster traffic to permit.

---

## Running it

Credentials come from `.env` — see [`.env.example`](../.env.example).

```bash
set -a; source .env; set +a
cd terraform

terraform init \
  -backend-config="access_key=$HETZNER_S3_ACCESS_KEY" \
  -backend-config="secret_key=$HETZNER_S3_SECRET_KEY"

terraform plan
terraform apply
```

State lives on Hetzner Object Storage (`backend.tf`) — the same bucket
production's Postgres backups use, under a separate key prefix. The bucket
must exist before `init`; the backend won't create it.

Per the original design, `apply` is meant to run from a gated GitHub Actions
`workflow_dispatch` rather than routinely from a laptop.

---

## Adding a server

Two places, both required:

1. `variables.tf`'s `nodes` list — `{name, env}`, where `name` exactly
   matches the real Hetzner server name.
2. `ansible/inventory/production.yml` — a matching host entry.

If the new node needs to be reachable by ArgoCD over the private network,
give it an `argocd_link_ip` in the inventory too — the `k3s_server` role
reads that to add `--tls-san`, without which its API server certificate
won't cover the private address.

---

## Status

This HCL has not been run through `terraform validate`/`plan`/`apply`
against real infrastructure — there was no `terraform` binary in the
environment it was authored in. Braces balance and resource references are
internally consistent on review, but treat it like an unreviewed first-pass
PR. Read it, run `plan`, and look at the diff before applying.

---

## Related

- [Server setup](setup-server.md) — where this fits in the bootstrap
- [Architecture](architecture.md) — the file-by-file breakdown
