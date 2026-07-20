# gami-infra

Infrastructure-as-code for the Gami / Authentic Memory platform: Kubernetes
manifests (Kustomize), GitOps delivery (ArgoCD), cluster bootstrap (Ansible),
and VPS provisioning (Terraform). The application code itself lives in a
separate repo (`gami-app`) — this repo only describes how it's deployed and
run.

This file explains what every piece is and how they fit together. For actual
step-by-step deployment instructions, use the environment-specific guide:

- **[README-local.md](README-local.md)** — run the whole stack on your own
  machine/VMs for development or testing the infra itself. No cloud account
  needed.
- **[README-dev.md](README-dev.md)** — deploy to the shared dev environment.
- **[README-staging.md](README-staging.md)** — deploy to the shared staging
  environment on the real 3-node Hetzner cluster.
- **[README-production.md](README-production.md)** — deploy to production.

Read this file first if you're new to the repo; jump to the guide that
matches what you're actually doing if you just need to get something running.

---

## Mental model

Three layers, each owned by a different tool:

```
Terraform   → creates VMs (Hetzner Cloud): network, firewall, 3 servers
              (differently sized — see "Node topology" below)
Ansible     → configures those VMs: installs k3s, joins them into one
              cluster, labels each node with its home environment,
              installs ArgoCD, does day-2 OS maintenance
ArgoCD      → watches THIS repo and applies the Kubernetes manifests in
              base/ + overlays/{dev,staging,production} — the actual app
              (gami-webapp, Postgres) runs because ArgoCD put it there,
              not because Ansible did
```

Terraform and Ansible are how the *cluster* comes to exist. Everything under
`base/`, `overlays/`, `cluster-wide/`, and `argocd/` is what ArgoCD
continuously reconciles onto that cluster. You run Terraform/Ansible rarely
(new node, cluster rebuild, OS patching); you change the Kustomize manifests
constantly (that's the actual day-to-day deploy path — commit, push, ArgoCD
picks it up).

For local development, Terraform is skipped entirely — you either already
have machines (real or VMs) or you use one machine as a single-node
stand-in — but Ansible and the ArgoCD/Kustomize layers work identically to
production. See [README-local.md](README-local.md).

**No separate backend service.** `gami-app` dropped its old Go backend
(`gami-api`) — confirmed against its actual `docker-compose.yml`, which only
ever defines `gami-webapp` (+ postgres/mailpit/caddy/init/migrate). The
Next.js `gami-webapp` is the whole app; crypto operations (signing, OTS
anchoring) run as a local binary/library inside it, not over a network API.
If you see `gami-api` referenced anywhere in
`.claude/plans/infrastructure-cicd-plan.md`, that's the older, superseded
design — see that file's own top-of-file notice.

---

## Node topology

Three VPS nodes, **deliberately sized differently and each "home" to one
environment**, rather than one uniform HA cluster running everything
identically:

| Node | Size | `env` label | Normally runs |
|---|---|---|---|
| `gami-node-dev` | small (`cx22`) | `dev` | ArgoCD (all its components), dev's `gami-webapp` (1 replica), dev's Postgres |
| `gami-node-staging` | small (`cx22`) | `staging` | staging's `gami-webapp` (1 replica), staging's Postgres |
| `gami-node-prod` | big (`cx42`) | `prod` | prod's Postgres primary; prod's `gami-webapp` spreads across **all 3** nodes, not just this one |

All 3 nodes still run the k3s **server** role (embedded-etcd HA control
plane — losing any single node still leaves a 2-of-3 quorum), regardless of
which environment they're "home" to. What differs is **workload placement**,
via Kubernetes node affinity — not 3 separate clusters. Terraform sets an
`env` Hetzner Cloud label on each node (`terraform/variables.tf`'s `nodes`
list); Ansible reads it back via the dynamic inventory
(`ansible/inventory/hcloud.yml`'s `keyed_groups`) and applies it as a real
Kubernetes node label at k3s install time (`--node-label env=...` in
`roles/k3s-server/tasks/{cluster-init,join}.yml`).

**Two different affinity strategies, deliberately**:
- **dev and staging** use a *soft* `nodeAffinity` preference
  (`preferredDuringSchedulingIgnoredDuringExecution`) toward their own node
  — keeps them off the other nodes' resources normally, but doesn't leave
  them stuck `Pending` forever if their home node is briefly unschedulable.
  Per the design intent, dev/staging don't need to survive losing a node —
  they're explicitly not meant to be highly reliable.
- **production** uses `podAntiAffinity` on `gami-webapp` instead — "prefer
  not to co-locate two `gami-webapp` pods on the same node." Combined with
  `replicas: 3` (one per node), this actually spreads production across all
  3 nodes, including the dev/staging nodes. That's what gives production
  real redundancy: losing any single node — even the dedicated big one —
  still leaves 2 of 3 replicas serving.

**Postgres is genuinely per-environment**, not one shared cluster:
- `overlays/dev/postgres-cluster.yaml` and `overlays/staging/postgres-cluster.yaml`
  are both single-instance CloudNativePG `Cluster`s, pinned to their own
  node, with **no backup configuration** — losing that pod just means
  recreating it, which matches dev/staging not needing high reliability.
- `overlays/production/postgres-cluster.yaml` is the only one with real HA
  (3 instances spread across all 3 nodes via `topologyKey:
  kubernetes.io/hostname`) **and** the only one that backs up to S3 (nightly
  scheduled + on-demand, via the CNPG Barman Cloud plugin — see
  `overlays/production/README-backup.md`). Two layers of redundancy for
  production specifically: CloudNativePG replicates at the Postgres level
  (streaming replication, automatic failover), and Longhorn replicates the
  underlying volume across nodes (survives total node/disk loss, not just
  process death).

---

## Repository layout

```
gami-infra/
├── terraform/          VPS provisioning (Hetzner Cloud) — staging/production/dev's real nodes only
├── ansible/             Cluster bootstrap + day-2 ops (all environments)
├── base/                 Kustomize base: the app's actual Kubernetes resources
├── overlays/
│   ├── dev/               Per-environment Kustomize overlay + secrets + Postgres
│   ├── staging/           Per-environment Kustomize overlay + secrets + Postgres
│   └── production/        Per-environment Kustomize overlay + secrets + Postgres + S3 backup
├── cluster-wide/         Cluster-scoped resources shared by every environment
├── cluster-operators/    Third-party operators (cert-manager, CNPG, backup plugin) — GitOps-managed, not manual
│   └── apps/               Child ArgoCD Applications for the operators (App-of-Apps pattern)
├── argocd/               ArgoCD Application definitions (what ArgoCD watches)
└── .claude/plans/        Design doc this repo was built from (historical record — see its own superseded-notice)
```

### `terraform/` — VPS provisioning

Provisions the Hetzner Cloud infrastructure: a private network, a firewall,
and 3 VPS nodes — `gami-node-dev`, `gami-node-staging`, `gami-node-prod` —
each with its own size and an `env` label (see "Node topology" above), plus
`role=k3s-server` on all 3 so Ansible's dynamic inventory can find them
without a hand-maintained IP list.

| File | Purpose |
|---|---|
| `main.tf` | The actual resources: `hcloud_ssh_key`, `hcloud_network` (+ subnet), `hcloud_firewall`, `hcloud_server` (one per entry in `var.nodes`, via `for_each` — not a uniform `count`) |
| `variables.tf` | Inputs: `hcloud_token` (secret), `admin_ip_cidr` (your IP, for SSH/k3s-API firewall rules), `ssh_public_key`, `location`, and `nodes` — the list of `{name, server_type, env}` objects that drives the differently-sized, differently-labeled nodes |
| `outputs.tf` | Node public/private IPs, names, and `env` labels, all keyed by node name — feeds Ansible |
| `backend.tf` | Remote state on Hetzner Object Storage (S3-compatible) — not a local `.tfstate` file, so CI runners see consistent state |
| `versions.tf` | Provider pin (`hetznercloud/hcloud ~> 1.45`), Terraform `>= 1.7` |
| `README.md` | Terraform-specific notes; flags that this HCL hasn't been run through `terraform validate`/`plan` yet — review before trusting it against real infra |

Firewall rules (`main.tf`): SSH (22) and the k3s API (6443) are restricted to
`admin_ip_cidr`/the private network — never `0.0.0.0/0`. HTTP/HTTPS (80/443)
are public (that's Traefik ingress). etcd (2379-2380) and Flannel VXLAN
(8472/udp) are private-network-only, node-to-node traffic.

**Only used for the real 3-node cluster.** Local development doesn't run
Terraform at all — see [README-local.md](README-local.md).

### `ansible/` — cluster bootstrap & maintenance

| Path | Purpose |
|---|---|
| `inventory/hcloud.yml` | **The real cluster.** Dynamic inventory sourced live from the Hetzner API via the `role=k3s-server` label Terraform sets — no IP list to maintain. Also defines `keyed_groups` on each node's `env` label (`hcloud_labels.env`), which `k3s-server`'s install tasks read to set the matching Kubernetes node label |
| `inventory/local.yml` | Single-machine local inventory (`ansible_connection: local`) |
| `inventory/alpine-local.yml` | Multi-VM local inventory for a 3-node Alpine test rig (static IPs, real SSH) |
| `playbooks/site.yml` | **The real bootstrap entrypoint** for staging/production: node baseline → first node does `k3s --cluster-init` → remaining nodes join. Idempotent, safe to re-run (how new nodes get added or drift gets reconciled) |
| `playbooks/local.yml` | Single-machine equivalent of `site.yml`, for `inventory/local.yml` |
| `playbooks/alpine-local.yml` | Multi-VM equivalent of `site.yml`, for `inventory/alpine-local.yml` — skips `node-baseline` (that role is apt/ufw-specific, written for the real Debian/Ubuntu production nodes, not a throwaway test rig) |
| `playbooks/patch-os.yml` | Day-2: rolling OS patch + reboot, one node at a time (`serial: 1`) — drains before rebooting so etcd quorum survives |
| `playbooks/cleanup-logs.yml` | Day-2: journald vacuum, containerd image prune, old pod log cleanup. Runs identically by hand or via a future ops-page GitHub Actions dispatch |
| `roles/node-baseline/` | OS hardening: unattended-upgrades, non-root `ops` user, ufw firewall mirroring Terraform's Hetzner firewall (defense in depth) |
| `roles/k3s-server/` | Installs k3s. `tasks/cluster-init.yml` bootstraps the first node with embedded etcd (`--cluster-init`); `tasks/join.yml` joins the rest. Both pass `--node-label env=<dev\|staging\|prod>` (read from the node's Hetzner label via `hostvars[...].hcloud_labels.env`) so Kubernetes scheduling (nodeAffinity/podAntiAffinity in the overlays) has something to match on. All 3 nodes run the **server** role (not agent) — that's what gives you an HA, odd-quorum embedded-etcd control plane; losing any one node still leaves 2/3 up |
| `roles/argocd/` | Installs ArgoCD itself (see below) |

**Why all 3 nodes are k3s servers, not 1 server + 2 agents**: etcd needs an
odd number of members to keep quorum after losing one. 3 servers means
losing any single node still leaves 2 — a working majority. This is a
deliberate HA design choice, not an oversight.

The `argocd` role does more than run `kubectl apply` on ArgoCD's install
manifest:
- Creates the `argocd` namespace (upstream's manifest doesn't)
- Applies with `--server-side --force-conflicts` (client-side apply chokes on
  the `applicationsets.argoproj.io` CRD — its schema exceeds Kubernetes'
  262144-byte last-applied-configuration annotation limit)
- Applies this repo's own `argocd/*.yaml` Application manifests
- Adds a **dedicated Traefik entrypoint** for the ArgoCD UI (`files/traefik-argocd-entrypoint.yaml`,
  a k3s `HelmChartConfig` — the supported way to customize k3s's bundled
  Traefik chart without the helm-controller overwriting direct edits) on a
  separate port from 80/443, since those are reserved for the app
- Sets `server.insecure: "true"` on `argocd-cmd-params-cm` and restarts
  `argocd-server` — **required**, not optional, when fronting ArgoCD with
  Traefik: without it, `argocd-server` self-terminates TLS and multiplexes
  HTTP/1.1 (UI/REST) and HTTP/2 (gRPC) on one port via protocol sniffing,
  which breaks when Traefik's HTTPS-to-backend transport negotiates HTTP/2
  by default — every UI request returns 404
- Applies `files/ingressroute.yaml`, a Traefik `IngressRoute` (not a plain
  `Ingress` — needed to bind to that dedicated entrypoint) routing to
  `argocd-server` over plain HTTP, with `tls: {}` so Traefik terminates TLS
  for the browser
- Patches every ArgoCD workload (`argocd-server`, `argocd-repo-server`,
  `argocd-applicationset-controller`, `argocd-dex-server`,
  `argocd-notifications-controller`, `argocd-application-controller`) with a
  soft `nodeAffinity` preference toward the `env=dev` node — ArgoCD is
  cluster-wide infra, not an environment itself, but it has to live
  somewhere, and the dev node is the small box it's sized to fit on (see
  "Node topology" above)

### `base/` — the application's Kubernetes manifests

Plain Kustomize base — boring, environment-agnostic resource definitions.
Both overlays start here and layer environment-specific values on top.

| File | Purpose |
|---|---|
| `gami-webapp/deployment.yaml` | `gami-webapp` Deployment — the whole app (no separate backend service, see the note above). Distroless (`gcr.io/distroless/nodejs22-debian13`), non-root (uid 65532), `readOnlyRootFilesystem`. `/api/public/health` liveness+readiness (pings Postgres — a real readiness signal, not a bare 200). Base default is `replicas: 1`; each overlay sets its own count (see the overlay table below) |
| `gami-webapp/service.yaml` | ClusterIP |
| `gami-webapp/ingress.yaml` | Traefik `Ingress`, two `Host` rules (`app.<domain>`, `verify.<domain>`) both routing to the same Service — the portal/verifier split happens in the app's own `src/middleware.ts`, not at the ingress layer |
| `gami-migrate-job.yaml` | A `batch/v1` Job run as an ArgoCD **PreSync hook** — runs `npm run db:setup` against the `-migrate` image tag (the builder stage, which still has npm/drizzle-kit/tsx; the distroless runtime image doesn't) and must complete before `gami-webapp` rolls out on every sync |
| `kustomization.yaml` | Ties the above together under `namespace: gami` (overridden per-overlay). Deliberately has **no** `configMapGenerator`, SealedSecrets, cert-manager, or Postgres resources — those are genuinely per-environment, added by each overlay (Postgres specifically: see "Node topology" above for why it's not one shared `base/postgres-cluster.yaml` anymore) |
| `README-image-pull-secret.md` | Explains why there's no `ghcr-pull-secret` manifest here: a real registry credential shouldn't be committed even sealed. Created once per cluster with a plain `kubectl create secret docker-registry` command instead |

### `overlays/{dev,staging,production}/` — per-environment configuration

Each overlay is a full Kustomize `Kustomization` referencing `../../base`
plus its own `sealed-secrets/` and its own `postgres-cluster.yaml`. What
differs between them:

| | dev | staging | production |
|---|---|---|---|
| Namespace | `gami-dev` | `gami-staging` | `gami` |
| Hostnames | `dev.authenticmemory.org`, `verify-dev.authenticmemory.org` | `staging.authenticmemory.org`, `verify-staging.authenticmemory.org` | `app.authenticmemory.org`, `verify.authenticmemory.org` |
| TLS issuer | `letsencrypt-staging` (untrusted test certs) | `letsencrypt-staging` (untrusted test certs) | `letsencrypt-production` (real, browser-trusted certs) |
| `gami-webapp` replicas | 1, soft nodeAffinity toward `env=dev` | 1, soft nodeAffinity toward `env=staging` | 3, podAntiAffinity spreads across all 3 nodes |
| Postgres | 1 instance, pinned to the dev node, no backup | 1 instance, pinned to the staging node, no backup | 3 instances (HA) spread across all 3 nodes, nightly + on-demand S3 backup |
| Secrets | `overlays/dev/sealed-secrets/` — independently generated | `overlays/staging/sealed-secrets/` — independently generated | `overlays/production/sealed-secrets/` — independently generated, never shared |

All three share `generatorOptions.disableNameSuffixHash: true` — without it,
Kustomize's default hash-suffixed ConfigMap name breaks every
`envFrom.configMapRef` in the Deployment/Job, which 404s at apply time (this
was verified against a real `kubectl kustomize` render, not assumed). The
trade-off: pods don't auto-restart when `gami-config` content changes — bump
a pod-template annotation manually when that matters.

`sealed-secrets/` starts as an **empty** `resources: []` Kustomization in
git — it's populated the first time an operator runs the secrets bootstrap
runbook (see each environment's README "Secrets" section) and never holds
plaintext.

### `cluster-wide/` — resources shared by every environment

Currently just `cert-manager/cluster-issuers.yaml` — two `ClusterIssuer`
resources (`letsencrypt-staging`, `letsencrypt-production`). These are
**cluster-scoped** Kubernetes resources, which is why they live outside
`base/`: `base/kustomization.yaml` sets a `namespace:`, and Kustomize's
namespace transformer would incorrectly stamp that onto a `ClusterIssuer`
(verified against a real render) — worse, both overlays would then fight to
own the same cluster-scoped resource name. `cluster-wide/kustomization.yaml`
deliberately has no `namespace:` field and is synced once, independently, via
its own ArgoCD Application.

### `cluster-operators/` — third-party operators, GitOps-managed

Third-party Kubernetes operators the app manifests depend on — cert-manager
(for `ClusterIssuer`/`Certificate`), the CloudNativePG operator (for the
`Cluster` CRD every `overlays/*/postgres-cluster.yaml` uses), and the CNPG
Barman Cloud plugin (production's S3 backup — see `overlays/production/README-backup.md`).

**These are installed the same way as everything else in this repo: as
ArgoCD `Application`s, not as a manual `kubectl apply` step or a separate
Ansible role.** Each subdirectory under `cluster-operators/` (not counting
`apps/`, see below) is a Kustomization referencing the operator's official
release manifest directly, pinned to an exact version — bumping the version
is a one-line URL change in git, reviewable as a normal diff, rather than an
unaudited `kubectl apply` against whatever `/latest/` happens to resolve to
at install time:

| Path | Installs |
|---|---|
| `cert-manager/kustomization.yaml` | cert-manager v1.21.0 |
| `cnpg/kustomization.yaml` | CloudNativePG operator v1.30.0. **Needs `ServerSideApply=true`** in the Application's `syncOptions` — its `clusters.postgresql.cnpg.io`/`poolers.postgresql.cnpg.io` CRDs exceed Kubernetes' 262144-byte last-applied-configuration annotation limit for client-side apply (confirmed by hand: plain `kubectl apply` fails with `metadata.annotations: Too long`) |
| `cnpg-barman-plugin/kustomization.yaml` | Barman Cloud CNPG-I plugin v0.13.0 — only needed for production's backups; depends on both cert-manager (its own mTLS cert/issuer) and the CNPG operator's CRDs already existing |
| `apps/` | The 3 child ArgoCD `Application` manifests that actually install the above (see below) |

**Ordering, and why it's an App-of-Apps, not 3 flat Applications**:
cert-manager and the CNPG operator have no dependency on each other, but the
Barman plugin needs *both* already up (it issues its own mTLS cert via
cert-manager and registers with the CNPG operator during install).
`argocd.argoproj.io/sync-wave` is the mechanism for that — **but it's only
honored when a sync operation is placing a resource into ordered waves. On a
standalone, directly-applied Application, the annotation is inert** (verified
against ArgoCD's own docs and maintainer guidance — this genuinely doesn't
work as 3 flat top-level Applications, it silently no-ops). The fix is
nesting: `argocd/app-cluster-operators.yaml` is a parent Application whose
"manifests" are the 3 child Applications in `cluster-operators/apps/`
(`cert-manager.yaml`, `cnpg.yaml` at wave `"0"`; `cnpg-barman-plugin.yaml` at
wave `"1"`). It's the **parent's own sync operation** that enforces "wave 0
fully Synced+Healthy before wave 1 starts" — that guarantee holds during the
parent's syncs (bootstrap, or any drift-triggered re-sync of the parent
itself), not as a standing invariant if the children auto-sync independently
afterward, which is fine for a one-time operator bootstrap like this.

**Why this replaced a manual step**: earlier, these operators were
documented (in `.claude/plans/infrastructure-cicd-plan.md`'s Rollout Order)
as something a human installs by hand, once, outside of Ansible or ArgoCD.
That's what caused a real incident on this repo's own test cluster — ArgoCD
tried to sync `overlays/staging`/`overlays/production` (which reference the
`Cluster` CRD) and `cluster-wide` (which references `ClusterIssuer`) before
anyone had actually run that manual step, so both failed with `SyncFailed:
... CRD is installed on the destination cluster`. Moving the install itself
into GitOps means it's no longer possible to forget: it happens
automatically the same way the app's own Kustomize manifests do, and
`selfHeal: true` means it can't be accidentally uninstalled either.

### `argocd/` — what ArgoCD watches

Five top-level `Application` manifests (one of which, `app-cluster-operators.yaml`,
is a parent whose own "resources" are 3 more child Applications defined under
`cluster-operators/apps/` — see above), applied once during cluster bootstrap
(by the `argocd` Ansible role, which does a plain `kubectl apply -f argocd/`
— every file in this directory gets applied, no per-file wiring needed) and
then self-managing from there (`syncPolicy.automated` with `prune: true,
selfHeal: true` — ArgoCD both applies new commits and reverts manual cluster
drift):

| File | Watches path | Destination namespace |
|---|---|---|
| `app-cluster-operators.yaml` | `cluster-operators/apps` (renders the 3 child Applications below) | `argocd` |
| `app-gami-cluster-wide.yaml` | `cluster-wide` | `default` (irrelevant for cluster-scoped resources, required by the schema) |
| `app-gami-dev.yaml` | `overlays/dev` | `gami-dev` |
| `app-gami-staging.yaml` | `overlays/staging` | `gami-staging` |
| `app-gami-production.yaml` | `overlays/production` | `gami` |

Child Applications rendered by `app-cluster-operators.yaml` (defined in
`cluster-operators/apps/`, not directly in `argocd/`):

| File | Watches path | Destination namespace | Sync wave |
|---|---|---|---|
| `cert-manager.yaml` | `cluster-operators/cert-manager` | `cert-manager` | 0 |
| `cnpg.yaml` | `cluster-operators/cnpg` | `cnpg-system` | 0 |
| `cnpg-barman-plugin.yaml` | `cluster-operators/cnpg-barman-plugin` | `cnpg-system` | 1 |

This is the actual GitOps loop: **commit a change to this repo → ArgoCD
notices the diff → applies it to the cluster.** There is no separate "deploy"
step beyond pushing to `main` (staging/production image tag bumps are
typically automated by `gami-app`'s release workflow, per the design plan in
`.claude/plans/infrastructure-cicd-plan.md`), and — as of the
`cluster-operators/` Applications above — no manual `kubectl apply` step
left for cluster bootstrap either.

### `.claude/plans/infrastructure-cicd-plan.md`

The original design document this repo was scaffolded from — CI/CD pipeline
design (GitHub Actions in the separate `gami-app` repo), the full secrets
bootstrap/rotation runbook, verification checklist, and rollout order. Kept
as a historical record and a deeper reference for *why* things are shaped
this way; the environment READMEs are the actionable, step-by-step version.

---

## Which guide do I want?

- Setting up a sandbox to learn the stack, test an Ansible change, or
  reproduce a bug without touching real infrastructure → **[README-local.md](README-local.md)**
- Deploying an app change to the shared dev environment →
  **[README-dev.md](README-dev.md)**
- Deploying an app change to the shared staging environment for QA →
  **[README-staging.md](README-staging.md)**
- Cutting a production release → **[README-production.md](README-production.md)**
