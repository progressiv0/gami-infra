# CI/CD & Infrastructure Automation Plan

## Context

App repo: `authenticmemory/gami-app` (moved from `progressiv0/gami`; `main` is
stale — `dev` is the real source of truth and what this plan is based on).
Infra repo (`gami-infra`, this repo) stays at `progressiv0/gami-infra` for now,
moves to `authenticmemory` later.

**What's already true on `dev` today** (verified against the actual branch,
not assumed):
- PostgreSQL migration is **already done** — `docker-compose.yml`,
  `drizzle.config.ts`, and `src/lib/db/index.ts` already run a single Postgres
  instance (`postgres:18-alpine`). `better-sqlite3` is gone. There is no HA/
  replication yet — that's the real remaining work, not the migration itself.
- `.github/workflows/ci.yml` already runs on every push to `dev`/`main` and on
  PRs: Go `vet`/`test` for `gami-core`/`gami-api`, and `next build` for the
  webapp. It is more than "checks if the backend compiles."
- `.github/workflows/deploy.yml` already does a **manual** (`workflow_dispatch`
  only) SSH deploy to a single Hetzner VPS (`159.69.83.49`), gated by an
  explicit "no prod changes until I say" policy. It already uses GitHub
  Actions secrets (`DEPLOY_HOST`, `DEPLOY_USER`, `DEPLOY_SSH_KEY`).

**Goal for this plan:**
- Push to `main` / open a PR → build, test, security-scan, and run an
  AI-assisted PR review automatically. No deploy.
- Cutting a GitHub Release (manual trigger) → automatically builds images,
  updates `gami-infra`, and rolls out to production. No manual SSH step.
- Three VPS nodes in a single k3s cluster with an HA (embedded-etcd) control
  plane — losing any one node keeps the cluster and the app serving.
- PostgreSQL HA (CloudNativePG) with streaming replication across nodes, on
  cross-node replicated storage (Longhorn) rather than node-local disk.
- Secrets: GitHub Secrets are fine for CI-side credentials (image push,
  `gami-infra` push token, Claude API key) — that constraint was relaxed.
  What we still avoid is putting cluster-admin/kubeconfig credentials in
  GitHub: ArgoCD *pulls* from `gami-infra`, nothing ever pushes into the
  cluster from outside it.
- VPS provisioning is Terraform (Hetzner `hcloud` provider), not manually-run
  bash scripts. Node configuration (k3s join, OS-level day-2 ops like log
  cleanup) is Ansible. Non-technical users trigger day-2 ops from a page in
  the existing Next.js portal, not a CLI.

---

## Architecture

```
GitHub Actions (authenticmemory/gami-app)          ArgoCD (self-hosted
  - PR/push to main: test + security scan           on cluster)
    + Claude PR review                          ──► watches gami-infra
  - Release published: build images,                applies manifests
    push to ghcr.io, bump tag in gami-infra           rolling deploy
                │                                          │
                └──────────────────────────────────────────┘
                                   │
                k3s Cluster — HA control plane, 3 nodes, embedded etcd
     ┌──────────────────┬──────────────────┬──────────────────┐
     │ VPS Node 1        │ VPS Node 2        │ VPS Node 3        │
     │ (k3s server)      │ (k3s server)      │ (k3s server)      │
     │ gami-api pod      │ gami-api pod      │ gami-webapp pod   │
     │ postgres primary  │ postgres replica  │ postgres replica  │
     │ ArgoCD            │ Longhorn          │ Longhorn          │
     │ Longhorn          │                   │                   │
     │ Caddy ingress     │ Caddy ingress     │ Caddy ingress     │
     └──────────────────┴──────────────────┴──────────────────┘
```

**On push to `main` / PR:**
1. GitHub Actions runs backend + webapp tests (existing `ci.yml`)
2. Security scans run: Trivy (deps + IaC), `gosec`, `npm audit` /
   dependency-review, optionally CodeQL
3. Claude reviews the PR automatically and leaves comments
4. Nothing is deployed

**On cutting a Release:**
1. Workflow builds `gami-api` and `gami-webapp` images, pushes to
   `ghcr.io/authenticmemory/*`
2. Updates the image tag in `gami-infra` (`charts/gami/values.yaml`) via a
   scoped push token, commits, pushes
3. ArgoCD (running in-cluster, watching `gami-infra`) detects the diff and
   applies the Helm release
4. k3s performs a rolling update — pods replaced one at a time, zero downtime
5. Pods are distributed across all 3 nodes — losing any one node doesn't take
   the app down

---

## Phase 1 — PostgreSQL (already done — nothing to migrate)

Verified on `dev`: `pg`/`drizzle-orm` are already the DB layer, Postgres
already runs as a `docker-compose` service, `DATABASE_URL` is already wired
through to the webapp. There is no SQLite left to remove and no schema
changes needed here.

The only remaining Postgres work is making the *existing* single instance
highly available — that's Phase 4, not this phase. This phase is kept in the
plan only as a record that it's done; no action items remain.

---

## Phase 2 — GitHub Actions: CI, Security Scanning, AI PR Review

Everything runs on GitHub-hosted runners — no self-hosted CI, no self-hosted
registry. This extends `authenticmemory/gami-app`'s existing
`.github/workflows/ci.yml` rather than replacing it.

**Add to `ci.yml`** (runs on every push to `main`/`dev` and every PR):

```yaml
  security-scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - name: Trivy filesystem scan
        uses: aquasecurity/trivy-action@master
        with:
          scan-type: fs
          exit-code: '1'
          severity: CRITICAL,HIGH
      - name: gosec (Go)
        run: |
          go install github.com/securego/gosec/v2/cmd/gosec@latest
          cd gami-backend && gosec ./...
      - name: npm audit (webapp)
        run: cd gami-webapp && npm audit --audit-level=high
      - name: Dependency review
        uses: actions/dependency-review-action@v4
        if: github.event_name == 'pull_request'

  claude-review:
    runs-on: ubuntu-latest
    if: github.event_name == 'pull_request'
    steps:
      - uses: actions/checkout@v6
      - uses: anthropics/claude-code-action@v1
        with:
          anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}
```

> CodeQL is worth adding too, but private repos need GitHub Advanced Security
> for code scanning — confirm the org's plan covers it before wiring it in.
> If not, `gosec` + Trivy + Semgrep's free tier cover most of the same OWASP
> ground for Go/JS.

**New `.github/workflows/release.yml`** (in `gami-app`):

```yaml
name: Release — build & deploy

on:
  release:
    types: [published]

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v6
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/build-push-action@v6
        with:
          context: ./gami-backend
          push: true
          tags: ghcr.io/authenticmemory/gami-api:${{ github.event.release.tag_name }}
      - uses: docker/build-push-action@v6
        with:
          context: ./gami-webapp
          push: true
          tags: ghcr.io/authenticmemory/gami-webapp:${{ github.event.release.tag_name }}

  update-infra-repo:
    needs: build-and-push
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
        with:
          repository: progressiv0/gami-infra
          token: ${{ secrets.INFRA_REPO_TOKEN }}
      - run: |
          sed -i "s|tag:.*|tag: ${{ github.event.release.tag_name }}|" charts/gami/values.yaml
          git config user.name "gami-release-bot"
          git config user.email "release-bot@authenticmemory.org"
          git commit -am "chore: release ${{ github.event.release.tag_name }}"
          git push
```

`INFRA_REPO_TOKEN` is a fine-grained PAT scoped only to `gami-infra` with
`contents: write` — stored as a GitHub Actions secret in `gami-app`. This
replaces `deploy.yml`'s SSH-based deploy entirely; releasing is the new
manual gate ("push to main never deploys; cutting a release does").

---

## Phase 3 — `gami-infra` Repository

```
gami-infra/
  charts/
    gami/
      Chart.yaml
      values.yaml          ← image tags live here; release workflow updates this
      templates/
        gami-api/          ← Deployment, Service, HPA
        gami-webapp/       ← Deployment, Service
        caddy/              ← DaemonSet (one per node), ingress
        postgres-cluster.yaml
        image-pull-secret.yaml   ← references a k8s Secret for ghcr.io
  argocd/
    app-gami.yaml
```

No Woodpecker, no self-hosted registry — both are gone from this design.
`gami-api`/`gami-webapp` pull from `ghcr.io/authenticmemory/*`, which needs an
`imagePullSecret` on the cluster (created once via an install script, see
Phase 5 — the credential lives only on the cluster, not in `gami-infra` git).

**ArgoCD Application** (`argocd/app-gami.yaml`) — unchanged from the
original design:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: gami
  namespace: argocd
spec:
  source:
    repoURL: https://github.com/progressiv0/gami-infra
    targetRevision: main
    path: charts/gami
  destination:
    server: https://kubernetes.default.svc
    namespace: gami
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

---

## Phase 4 — PostgreSQL HA (CloudNativePG + Longhorn)

```yaml
# gami-infra/charts/gami/templates/postgres-cluster.yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: gami-postgres
spec:
  instances: 3                  # one per node, matches the 3-node cluster
  affinity:
    topologyKey: kubernetes.io/hostname   # one instance per node, never doubled up
  storage:
    storageClass: longhorn
    size: 10Gi
  postgresql:
    pg_hba:
      - host gami gami 10.0.0.0/8 scram-sha-256
  backup:
    retentionPolicy: "7d"
```

Two layers of redundancy here, intentionally:
- **CloudNativePG** replicates at the Postgres level (streaming replication,
  ~30s automatic failover if the primary pod dies).
- **Longhorn** replicates the underlying volume across nodes, so a instance's
  data survives even total disk/node loss, not just process death — k3s's
  default `local-path` provisioner ties a PV to one node, which would break
  losing that node entirely.

`DATABASE_URL` is served via the CNPG-managed Service that always points at
the current primary — the webapp never needs to know which node that is.

---

## Phase 5 — VPS Provisioning (Terraform) + Node Config (Ansible)

No manually-run bash scripts. Terraform provisions the Hetzner infrastructure;
Ansible configures the OS and joins the k3s cluster; both are re-runnable and
version-controlled in `gami-infra`.

```
gami-infra/
  terraform/
    main.tf              ← hcloud_server x3, hcloud_network, hcloud_firewall, ssh key
    backend.tf            ← S3-compatible backend on Hetzner Object Storage
    variables.tf / outputs.tf   ← outputs the 3 node IPs for Ansible's inventory
  ansible/
    inventory/hcloud.yml  ← dynamic inventory sourced from Terraform/hcloud API
    playbooks/
      site.yml             ← k3s install + join (idempotent, safe to re-run)
      cleanup-logs.yml      ← journalctl vacuum, docker/containerd image prune, Caddy log rotation
      patch-os.yml          ← unattended-upgrades / apt/dnf patch + reboot-if-needed
    roles/
      k3s-server/
      node-baseline/        ← firewall, unattended-upgrades, non-root ops user
```

**Terraform** (`terraform/main.tf`, Hetzner `hcloud` provider):
```hcl
resource "hcloud_network" "gami" {
  name     = "gami-private"
  ip_range = "10.0.0.0/16"
}

resource "hcloud_server" "node" {
  count       = 3
  name        = "gami-node-${count.index + 1}"
  server_type = "cx32"
  image       = "ubuntu-24.04"
  location    = "fsn1"
  ssh_keys    = [hcloud_ssh_key.ops.id]
  network {
    network_id = hcloud_network.gami.id
  }
}

resource "hcloud_firewall" "gami" {
  name = "gami-firewall"
  rule { direction = "in" protocol = "tcp" port = "22"   source_ips = [var.admin_ip_cidr] }
  rule { direction = "in" protocol = "tcp" port = "6443" source_ips = [hcloud_network.gami.ip_range] }
}
```

State backend (`terraform/backend.tf`) points at Hetzner Object Storage
(S3-compatible), not a local file:
```hcl
terraform {
  backend "s3" {
    bucket                      = "gami-tfstate"
    key                         = "infra/terraform.tfstate"
    region                      = "eu-central"
    endpoints                   = { s3 = "https://fsn1.your-objectstorage.com" }
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
  }
}
```
The bucket access key/secret is passed via `AWS_ACCESS_KEY_ID`/
`AWS_SECRET_ACCESS_KEY` env vars at `terraform apply` time — never committed.
`terraform apply` runs from a GitHub Actions `workflow_dispatch` (same
click-to-run pattern as everything else in this plan) so infra changes are
still gated behind a manual trigger and leave an audit trail, without anyone
needing Terraform installed locally.

**Ansible** takes it from there: `playbooks/site.yml` runs against the 3 IPs
Terraform just created (via a dynamic `hcloud` inventory, so there's no IP
list to hand-maintain) and installs k3s with embedded etcd — node 1 with
`--cluster-init`, nodes 2/3 joining via `--server https://<node1-ip>:6443`.
All three run the k3s **server** role, so losing any single node still
leaves 2 of 3 etcd members up (a 2-node cluster can't do this — etcd needs an
odd member count to keep quorum after losing one). This replaces the old
per-node bash scripts entirely; re-running `site.yml` is safe and is how new
nodes get added or existing ones get reconciled.

**Registry note:** images come from `ghcr.io` (managed, valid TLS), so there's
no insecure-registry/containerd config needed — just an `imagePullSecret`
created once via a small Ansible task or `kubectl create secret`, applied
directly to the cluster and never committed to git.

> **Note on GPR file store:** GPR JSON files are NOT managed as a K8s
> persistent volume in production. They remain on local node storage written
> directly by the webapp pod. Replication across nodes is out of scope for
> this automation.

All nodes communicate over the `hcloud_network` private network (not public
internet); only port 22 (from an admin CIDR) and the k3s API port are exposed
externally per the firewall above.

---

## Phase 6 — Self-Serve Ops (backup, restore, log cleanup) from the portal

Goal: someone without kubectl/SSH/Ansible knowledge can do routine ops from a
page in the existing Next.js portal (`gami-webapp`). Split by where the task
actually lives — database ops stay in Kubernetes, host ops stay in Ansible —
rather than forcing everything through one tool:

**Database backup** (`/admin/ops` page, new `platform-admin`-only role,
separate from the existing institution/admin roles):
- Backend calls the in-cluster Kubernetes API (via a `ServiceAccount` bound
  to a `Role` scoped to *only* `create`/`get` on
  `backups.postgresql.cnpg.io` in the `gami` namespace — nothing broader)
  to create an on-demand CNPG `Backup` object.
- Polls until CNPG reports it complete; CNPG has already pushed it to the
  Hetzner Object Storage bucket (same barman-cloud target configured in
  Phase 4's `backup:` block).
- Backend generates a presigned S3-style URL for that object and the page
  offers it as a download. No SSH, no Ansible, no kubeconfig ever touches
  the webapp — just the narrowly-scoped in-cluster service account token
  it already gets for free as a pod.

**Database restore**: reachable from the same page but deliberately not a
single click — CNPG's restore model is "bootstrap a new `Cluster` from a
backup/PITR target," which is inherently a bigger, order-sensitive operation.
Gate it behind a typed confirmation (e.g. type the environment name) and
restrict it to `platform-admin`, regardless of how nice the button looks.

**Log cleanup / OS-level maintenance** (host disk, not Kubernetes): the page
calls the GitHub API (`POST .../actions/workflows/ops.yml/dispatches`) on
`gami-infra`, using a fine-grained PAT (scoped to `actions: write` on just
that repo) held server-side in the webapp's environment. That dispatches
`ansible/playbooks/cleanup-logs.yml` on a GitHub Actions runner over SSH —
the SSH private key lives only in that GitHub Actions secret, never in the
webapp's container or image. This mirrors the existing manual-deploy pattern
the team already trusts, just triggered by a button instead of the Actions
tab.

---

## Verification

1. **PostgreSQL**: already verified working on `dev` (`docker compose up`,
   drizzle-kit push, login). Nothing to re-verify for Phase 1.
2. **CI on push/PR**: push a branch or open a PR — confirm tests, security
   scans, and the Claude review comment all run.
3. **Release deploy**: publish a GitHub Release — confirm the workflow builds
   images, updates `gami-infra`, and ArgoCD rolls out the change. Confirm a
   plain push to `main` does *not* deploy.
4. **Control-plane HA**: stop k3s on any one of the 3 nodes
   (`systemctl stop k3s`) — confirm the other two keep serving traffic and
   the API server stays reachable within ~60s.
5. **PostgreSQL failover**: delete the primary postgres pod — confirm
   CloudNativePG promotes a replica and the webapp reconnects automatically.
6. **Storage resilience**: cordon/drain the node hosting a Postgres replica's
   Longhorn volume — confirm Longhorn keeps the data available from its other
   replicas.
7. **Security scan gate**: introduce a known-vulnerable dependency — confirm
   Trivy/`npm audit`/`gosec` blocks the PR.
8. **Terraform**: `terraform plan` on a clean checkout shows no drift against
   the running Hetzner infra; `terraform apply` via the `workflow_dispatch`
   workflow succeeds end-to-end against the S3-compatible state backend.
9. **Ansible**: re-running `site.yml` against all 3 nodes is a no-op (proves
   idempotency); `cleanup-logs.yml` run once by hand, then again via the
   `/admin/ops` button, to confirm both paths work identically.
10. **Ops page**: as `platform-admin`, trigger a backup and confirm a working
    download link appears; confirm a non-`platform-admin` user cannot see or
    trigger any of `/admin/ops`.

---

## Rollout Order
1. Security + Claude review jobs added to `ci.yml` (low risk, no infra needed)
2. `release.yml` workflow added to `gami-app`, `INFRA_REPO_TOKEN` +
   `ANTHROPIC_API_KEY` secrets set
3. `gami-infra` repo scaffolded: Helm charts, ArgoCD Application, Terraform
   (`terraform/`), Ansible (`ansible/`)
4. Hetzner Object Storage bucket created for Terraform state; `terraform
   apply` (via `workflow_dispatch`) provisions the 3-node network + firewall
   + servers
5. `ansible-playbook site.yml` installs k3s with embedded etcd across all 3
   nodes (HA control plane)
6. Longhorn + ArgoCD + CloudNativePG installed on the cluster; `imagePullSecret`
   for `ghcr.io` created
7. First GitOps deploy via a test Release
8. HA validation (control plane, Postgres failover, storage resilience)
9. `platform-admin` role + `/admin/ops` page added to `gami-webapp`: backup
   download wired to the CNPG/Kubernetes API, log cleanup wired to the
   `ops.yml` GitHub Actions dispatch
10. Cut over production traffic from the current single Hetzner VPS to the
    cluster; retire `deploy.yml` and the old VPS once confirmed stable
