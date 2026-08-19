# gami-infra

Infrastructure-as-code for the Gami / Authentic Memory platform: Kubernetes
manifests (Kustomize), GitOps delivery (ArgoCD), cluster bootstrap (Ansible),
and VPS networking (Terraform). The application code itself lives in a
separate repo (`gami-app`) — this repo only describes how it's deployed and
run.

This file explains what every piece is and how they fit together. For actual
step-by-step deployment instructions, use the environment-specific guide:

- **[README-local.md](README-local.md)** — run the whole stack on your own
  machine/VM for development or testing the infra itself. No cloud account
  needed.
- **[README-staging.md](README-staging.md)** — deploy to the real staging
  environment, and bootstrap the two-cluster setup for the first time.
- **[README-production.md](README-production.md)** — deploy to production.

Read this file first if you're new to the repo; jump to the guide that
matches what you're actually doing if you just need to get something running.

---

## Mental model

Three layers, each owned by a different tool:

```
Terraform   → attaches networking/firewalls to 2 pre-existing Hetzner VPS
              nodes (staging, prod) — it never creates, resizes, or
              destroys the servers themselves; see "Node topology" below
Ansible     → configures those 2 nodes: installs k3s independently on
              each (no joining — each node is its own single-node
              cluster), installs the one central ArgoCD instance on
              staging, and registers production with it as a remote
              cluster, does day-2 OS maintenance
ArgoCD      → runs only on staging, watches THIS repo, and applies the
              Kubernetes manifests in base/ + overlays/{staging,production}
              — locally onto staging, and remotely onto the registered
              production cluster — the actual app (gami-webapp, Postgres)
              runs because ArgoCD put it there, not because Ansible did
```

Terraform and Ansible are how the *clusters* come to exist. Everything under
`base/`, `overlays/`, `cluster-wide/`, and `argocd/` is what ArgoCD
continuously reconciles onto them. You run Terraform/Ansible rarely (new
node, cluster rebuild, OS patching); you change the Kustomize manifests
constantly (that's the actual day-to-day deploy path — commit, push, ArgoCD
picks it up).

For local development, Terraform is skipped entirely and there's only one
machine — but Ansible and the ArgoCD/Kustomize layers work identically to
staging (the local rig mirrors staging exactly, single node, nothing to
register as remote). See [README-local.md](README-local.md).

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

**Two pre-existing Hetzner VPS nodes, both the same size (`cx22`), each its
own fully independent, unjoined k3s cluster** — not one shared HA cluster.
There used to be a third (dev) node in a shared 3-node cluster; dev is gone
entirely now, and the remaining two nodes were split apart into separate
single-node clusters:

| Node | Public IP | `env` | Runs |
|---|---|---|---|
| `gami-staging` | *(not committed — see below)* | `staging` | k3s (its own cluster), the **one central ArgoCD instance** (manages both clusters), staging's `gami-webapp` + plain Postgres + Mailpit |
| `gami-prod` | *(not committed — see below)* | `prod` | k3s (its own cluster, completely separate from staging's), production's `gami-webapp` + CNPG Postgres — **no ArgoCD installed here** |

Real public IPs are deliberately kept out of this (public) repo —
`ansible/inventory/production.yml` reads them from the `GAMI_STAGING_IP`/
`GAMI_PROD_IP` environment variables at run time instead of hardcoding them.
Same principle everywhere else a real credential would otherwise need to
live in git (Hetzner API token, SSH key, ArgoCD's git repo access if this
repo is private) — **`.env.example` at the repo root is the single list of
every environment variable this repo's automation reads**, with a note on
which tool consumes each one and which are optional.

**Neither node is created by Terraform.** Both already exist in Hetzner;
`terraform/main.tf` uses `data "hcloud_server"` lookups by name (read-only)
against them, never `resource "hcloud_server"`. Terraform can attach
networking and firewall rules to these servers, but it can never create,
resize, or destroy them. A `terraform plan` that proposes touching either
server (rather than just the network/firewall resources around them) means
something is misconfigured — stop and investigate before applying. Adding a
third server later means adding an entry to `terraform/variables.tf`'s
`nodes` list (just `{name, env}` now — no `server_type`, since there's no
"differently sized" story anymore) and a matching host in
`ansible/inventory/production.yml`.

**Each node bootstraps its own single-node embedded-etcd k3s server,
independently.** `ansible/playbooks/site.yml` runs `node_baseline` then the
`k3s_server` role on every node — that role only ever does
`k3s server --cluster-init`, nothing joins anything else. There's no etcd
peer traffic, no Flannel VXLAN between the nodes, no shared private network
for clustering purposes, and no two-phase "first node bootstraps, others
join" logic (the old `roles/k3s_server/tasks/join.yml` is deleted).

**ArgoCD installs once, on staging, and manages production as a registered
remote cluster** — ArgoCD's standard multi-cluster pattern, not a second
ArgoCD install. Staging's Applications use `destination.server:
https://kubernetes.default.svc` (unchanged — correct precisely because
ArgoCD runs on staging); production's Applications use `destination.name:
prod`. The registration itself is a Secret in the `argocd` namespace labeled
`argocd.argoproj.io/secret-type: cluster`, containing production's k3s API
URL, a bearer token, and a CA cert — created by
`ansible/roles/argocd/tasks/register-remote-cluster.yml`, which:
1. Creates an `argocd-manager` ServiceAccount + `cluster-admin`
   ClusterRoleBinding on the **prod** node (delegated to over SSH from the
   staging play).
2. Requests and reads back its ServiceAccount token (k3s 1.24+ doesn't
   auto-create one).
3. Renders and applies the cluster-registration Secret
   (`templates/cluster-secret.yaml.j2`) to **staging's** ArgoCD.

Rationale for this shape (per the design intent): it keeps production's node
"clean" — no ArgoCD control-plane pods competing with the app for resources
on the box that's supposed to be running the real workload.

**Networking**: there's no general shared private network between the two
nodes anymore — nothing joins, so there's nothing that needs node-to-node
connectivity by default. A small **dedicated** private network
(`gami-argocd-link`, `10.10.0.0/24`, staging pinned to `10.10.0.2`, prod to
`10.10.0.3`) exists solely so staging's ArgoCD can reach prod's k3s API
(port 6443) to manage it remotely — prod's firewall only opens 6443 to that
dedicated subnet, not generally. The old etcd (2379-2380) and Flannel VXLAN
(8472/udp) firewall rules are gone (nothing joins). SSH (22) and the k3s API
(6443) on the **public** interface are restricted to `admin_ip_cidr` (your
own IP), not scoped to a shared private network the way they might be in a
joined-cluster design — there's no such shared network to scope to. The
ArgoCD web UI (NodePort **30443**, staging only) is restricted the same way:
80/443 are the only genuinely public ports, and they're the app's.

**The two environments deliberately run different Postgres setups**, because
they need different things:
- **Staging** (`overlays/staging/postgres.yaml`): a plain, unmanaged
  `postgres:18-alpine` Deployment + 25Gi `local-path` PVC + Service — **no
  CNPG operator at all**, and **no backup**. A documented, deliberate
  tradeoff (staging doesn't need to survive data loss the way production
  does), not an oversight. Because nothing generates credentials here, its
  `gami-postgres-app` Secret is generated on the cluster by Ansible's
  `app_secrets` role instead — one Secret serving both the Postgres container
  (`envFrom` → `POSTGRES_*`) and the app (`secretKeyRef` → `uri`), created
  once and never rotated by a re-run. Staging therefore installs none of the
  CNPG operator, the Barman plugin, or the sealed-secrets controller.
- **Production** (`overlays/production/database/postgres-cluster.yaml`) runs
  CloudNativePG at `instances: 1` — never multi-instance/HA, since there's
  only one node and cross-node replication is structurally impossible. CNPG
  is there purely for its Barman Cloud backup/restore tooling. It gets
  20Gi `local-path` storage, and backup is not just kept but improved. A
  nightly `ScheduledBackup` (02:00) ships a base backup to S3 with 30-day
  retention via the Barman Cloud plugin, **plus** `postgresql.parameters.
  archive_timeout: "60s"` forces continuous WAL archiving on a timer
  (instead of only when a 16MB segment fills), bounding data loss to about a
  minute — true point-in-time recovery (PITR), not just "restore last
  night's snapshot." This matters because the app's workload is
  batch-driven; losing an in-flight batch is worse than losing a minute of
  one. See `overlays/production/database/README-backup.md` for the full
  detail and the restore-drill procedure.

All Postgres PVCs on both clusters use k3s's bundled `local-path` storage
class — there's no second node on either cluster for a replicated
block-storage layer (e.g. Longhorn) to spread across, so it would buy
nothing.

**Production's database and webapp are still two separate ArgoCD
Applications** (`overlays/production/database/` and
`overlays/production/webapp/`): the database is deployed today, ahead of the
web app, since the app's own branches/images aren't ready yet. Bringing the
webapp online later is just adding `app-gami-production-webapp.yaml` to
`argocd_remote_apps` (`ansible/roles/argocd/defaults/main.yml`) — no other
change needed. Production's `gami-webapp` no longer has any node-loss HA
story either way: `overlays/production/webapp/kustomization.yaml` no longer
overrides `replicas` (uses `base/`'s own default of 1, down from 3) and its
`podAntiAffinity` patch is gone — there's only one node in production's
cluster, nothing to spread pods across. A pod crash still gets Kubernetes'
normal restart; it just doesn't survive losing the node, because there's no
second node to fail over to.

---

## Repository layout

```
gami-infra/
├── terraform/          Networking/firewall attachment for 2 pre-existing Hetzner nodes
├── ansible/             Cluster bootstrap + day-2 ops (both nodes, independently)
├── base/                 Kustomize base: the app's actual Kubernetes resources
├── overlays/
│   ├── staging/           Full Kustomize overlay + secrets + plain Postgres (no backup) + Mailpit
│   └── production/
│       ├── database/       CNPG Postgres + S3 backup + PITR — own ArgoCD Application, deployed now
│       └── webapp/          gami-webapp/gami-migrate — own ArgoCD Application, deployed later
├── cluster-wide/         Cluster-scoped resources, synced independently onto EACH cluster
├── cluster-operators/    Third-party operators (cert-manager, CNPG, Sealed Secrets, backup plugin) — GitOps-managed, not manual
│   ├── apps-staging/       Child ArgoCD Applications installing the operators onto staging
│   └── apps-production/    Same, onto production (via the registered remote cluster) — plus the Barman plugin
├── argocd/               ArgoCD Application definitions (what ArgoCD watches, and where)
└── .claude/plans/        Design doc this repo was built from (historical record — see its own superseded-notice)
```

### `terraform/` — VPS networking

Attaches networking and firewall rules to the 2 already-provisioned Hetzner
servers (`gami-staging`, `gami-prod`) — never provisions the servers
themselves.

| File | Purpose |
|---|---|
| `main.tf` | `data "hcloud_server"` lookups (by name) for both nodes — read-only, never `resource`. Then: `hcloud_network`/`hcloud_network_subnet` for the dedicated `gami-argocd-link` network, `hcloud_server_network` pinning each node's address on it (staging `10.10.0.2`, prod `10.10.0.3`), the main `hcloud_firewall` (22/6443 admin-IP-only, 80/443 public), a second `hcloud_firewall` scoped to the `argocd-link` subnet attached only to prod opening 6443 to it, and a third opening the ArgoCD UI's NodePort 30443 to `admin_ip_cidr`, attached only to staging |
| `variables.tf` | Inputs: `hcloud_token` (secret), `admin_ip_cidr` (your IP, for SSH/k3s-API firewall rules), `location`, and `nodes` — a list of `{name, env}` objects, one per pre-existing server this repo manages networking for. This is the "add a server" list — add an entry here (name must exactly match the real Hetzner server name) plus a matching host in `ansible/inventory/production.yml` |
| `outputs.tf` | `node_public_ips`, `node_argocd_link_ips` (the dedicated-network addresses — prod's feeds Ansible's remote-cluster registration), `node_names`, `node_envs` |
| `backend.tf` | Remote state on Hetzner Object Storage (S3-compatible) — not a local `.tfstate` file, so CI runners see consistent state. Same bucket production's Postgres backups use, under a separate key prefix |
| `versions.tf` | Provider pin (`hetznercloud/hcloud ~> 1.45`), Terraform `>= 1.7` |
| `README.md` | Terraform-specific notes; flags that this HCL hasn't been run through `terraform validate`/`plan` yet — review before trusting it against real infra |

Firewall rules: SSH (22) and the k3s API (6443) on the public interface are
restricted to `admin_ip_cidr` — never `0.0.0.0/0`. HTTP/HTTPS (80/443) are
public (that's Traefik ingress). There are **no** etcd or Flannel VXLAN
rules anymore — nothing joins, so there's no node-to-node cluster traffic to
permit. The one deliberate hole between the two nodes is 6443 on the
dedicated `gami-argocd-link` subnet, open only to prod, only for staging's
ArgoCD to reach it.

**Only used for the real 2-node infrastructure.** Local development doesn't
run Terraform at all — see [README-local.md](README-local.md).

### `ansible/` — cluster bootstrap & maintenance

| Path | Purpose |
|---|---|
| `inventory/production.yml` | **The real infrastructure.** Static, hand-maintained YAML — not the dynamic hcloud plugin this repo used to use, since Terraform no longer owns these servers via the API and can't label them for dynamic discovery anymore. Declares `gami-staging`/`gami-prod` with their public IPs and `hcloud_labels.env` directly, plus `env_staging`/`env_prod` groups (which `site.yml` uses to target ArgoCD install/registration at staging specifically) and prod's `argocd_link_ip` |
| `inventory/local.yml` | Single-machine local inventory (`ansible_connection: local`) |
| `playbooks/site.yml` | **The real bootstrap entrypoint.** `node_baseline` on both nodes → `k3s_server` (single-node `--cluster-init`) independently on both nodes → `app_secrets` on staging → install ArgoCD on staging only → register production as a remote cluster in staging's ArgoCD. Idempotent, safe to re-run (how a new node gets added or drift gets reconciled) |
| `playbooks/local.yml` | Single-machine equivalent, mirroring staging (see [README-local.md](README-local.md)) |
| `playbooks/patch-os.yml` | Day-2: rolling OS patch + reboot, one node at a time (`serial: 1`, kept as a light habit — not for any quorum reason, since there's no shared quorum anymore). No longer drains/uncordons before rebooting — that used to delegate to "some other node in the shared cluster," which doesn't exist; each node is its own single-node cluster with nowhere to evacuate to |
| `playbooks/cleanup-logs.yml` | Day-2: journald vacuum, containerd image prune, old pod log cleanup |
| `roles/node_baseline/` | OS hardening: unattended-upgrades, non-root `ops` user, ufw firewall mirroring Terraform's Hetzner firewall (defense in depth) |
| `roles/k3s_server/` | Installs k3s. `tasks/cluster-init.yml` is the **only** task file now — every node runs `--cluster-init` independently; there's no `join.yml` anymore (deleted along with the joined-cluster design) |
| `roles/app_secrets/` | Generates staging's `gami-postgres-app` (DB credentials) and `gami-secrets` (`NEXTAUTH_SECRET`) directly on the cluster, so neither is ever sealed into git. Runs before ArgoCD so they exist on its first sync. **Generate-once**: each is created only if absent, because `POSTGRES_PASSWORD` is read solely by initdb on the database's first start (rotating it would lock the app out of its own data) and rotating `NEXTAUTH_SECRET` invalidates live sessions. ArgoCD never prunes them — it only prunes what it created |
| `roles/argocd/` | Installs ArgoCD on staging, applies its local Application manifests, and (via `tasks/register-remote-cluster.yml`) registers production as a remote cluster (see below) |

The `argocd` role does more than run `kubectl apply` on ArgoCD's install
manifest:
- Creates the `argocd` namespace (upstream's manifest doesn't)
- Applies with `--server-side --force-conflicts` (client-side apply chokes on
  the `applicationsets.argoproj.io` CRD — its schema exceeds Kubernetes'
  262144-byte last-applied-configuration annotation limit)
- Applies `argocd_local_apps` — the Application manifests that run against
  staging itself (see `defaults/main.yml` below)
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
- Patches `argocd-cm` with a custom Ingress health check (see the Gotchas
  section of [README-local.md](README-local.md))
- Then, as a separate play in `site.yml` (`tasks_from:
  register-remote-cluster.yml`), wires up production as a registered remote
  cluster — creates the `argocd-manager` ServiceAccount/ClusterRoleBinding
  on prod, reads its token and CA cert, and applies the resulting
  cluster-registration Secret to staging's ArgoCD, then applies
  `argocd_remote_apps` against it

`ansible/roles/argocd/defaults/main.yml` replaces the old single
`argocd_gami_environments` list with two:
- **`argocd_local_apps`** — applied against staging locally:
  `app-cluster-operators-staging.yaml`, `app-gami-cluster-wide-staging.yaml`,
  `app-gami-staging.yaml`.
- **`argocd_remote_apps`** — applied against the registered prod cluster:
  `app-cluster-operators-production.yaml`, `app-gami-cluster-wide-production.yaml`,
  `app-gami-production-database.yaml` — deliberately **not**
  `app-gami-production-webapp.yaml` yet, same "add it once the app is ready"
  deferred-activation pattern as before.

Local playbooks (`playbooks/local.yml`) override `argocd_local_apps` to the
same staging-mirroring file set and set `argocd_remote_apps: []` — a local
rig is single-cluster, there's nothing to register.

### `base/` — the application's Kubernetes manifests

Plain Kustomize base — boring, environment-agnostic resource definitions.
Both overlays start here and layer environment-specific values on top.

| File | Purpose |
|---|---|
| `gami-webapp/deployment.yaml` | `gami-webapp` Deployment — the whole app (no separate backend service, see the note above). Runs as non-root uid 1000 (the `node` user in the app's `node:22-alpine` runtime image — it is **not** distroless, despite what an earlier version of this doc claimed). `readOnlyRootFilesystem: false`, because `next start` writes `.next/cache` and npm needs a writable HOME. `command: ["npm", "start"]` overrides the image's ENTRYPOINT, which would otherwise re-run `drizzle-kit push` + seed on every pod start — `gami-migrate-job.yaml` owns migrations here. `/api/version` liveness+readiness: a static 200 that reports `BUILD_SHA`; the app exposes no health route, and probing a DB-touching endpoint would take the Deployment down on any database blip. Default `replicas: 1` — staging explicitly sets 1 too; production no longer overrides it at all (used to be 3 with podAntiAffinity, see "Node topology" above) |
| `gami-webapp/service.yaml` | ClusterIP |
| `gami-webapp/ingress.yaml` | Traefik `Ingress`, two `Host` rules (`app.<domain>`, `verify.<domain>`) both routing to the same Service — the portal/verifier split happens in the app's own `src/middleware.ts`, not at the ingress layer |
| `gami-migrate-job.yaml` | A `batch/v1` Job — runs `npm run db:setup` against the **same image as the webapp**, just a different command. There is no separate `-migrate` build: the Dockerfile's runtime stage copies `node_modules` wholesale (installed with devDependencies, so `drizzle-kit`/`tsx` are present) plus `src/`, `scripts/` and `drizzle.config.ts`. Ordered via `argocd.argoproj.io/sync-wave` (`-1`: `gami-config` → `0`: this Job → `1`: `gami-webapp`'s Deployment, patched per overlay), **not** a PreSync hook — an earlier PreSync-hook version of this Job could never see `gami-config` (hooks run in a phase that completes entirely before any Sync-phase resource, including that ConfigMap, is even attempted). `argocd.argoproj.io/sync-options: Replace=true` on the Job makes repeated syncs of this fixed name idempotent (Jobs are immutable, so plain re-apply fails once one has run) |
| `kustomization.yaml` | Ties the above together under `namespace: gami` (overridden per-overlay). Deliberately has **no** `configMapGenerator`, SealedSecrets, cert-manager, or Postgres resources — those are genuinely per-environment, added by each overlay |
| `README-image-pull-secret.md` | Explains why there's no `ghcr-pull-secret` manifest here: a real registry credential shouldn't be committed even sealed. Created once per cluster with a plain `kubectl create secret docker-registry` command instead |

### `overlays/{staging,production}/` — per-environment configuration

Staging is a full Kustomize `Kustomization` referencing `../../base` plus
`postgres.yaml` (a plain `postgres:18-alpine` Deployment, no operator, no
backup), `mailpit.yaml`, and `gpr-store-pvc.yaml` (persistent storage for the
app's on-disk GPR files — staging only). It has no `sealed-secrets/` at all;
its Secrets are generated on the cluster by Ansible. Production is split into two sibling
Kustomizations/ArgoCD Applications instead — `database/` (CNPG `Cluster` +
S3 backup + PITR) and `webapp/` (`../../base` + `sealed-secrets/`) — so the
database can deploy independently of the web app. What differs between the
two:

| | staging | production |
|---|---|---|
| Namespace | `gami-staging` | `gami` |
| Cluster | `gami-staging` node, ArgoCD's local destination | `gami-prod` node, ArgoCD's registered remote `prod` destination |
| Hostnames | `staging.authenticmemory.org`, `verify-staging.authenticmemory.org` | `app.authenticmemory.org`, `verify.authenticmemory.org` |
| TLS issuer | `letsencrypt-staging` (untrusted test certs) | `letsencrypt-production` (real, browser-trusted certs) |
| `gami-webapp` replicas | 1 (no nodeAffinity/podAntiAffinity — one node, nothing to schedule around) | 1 (base's own default — no override, no podAntiAffinity; there's only one node, no node-loss HA story anymore) |
| Postgres | CNPG, 1 instance, **no backup** (documented tradeoff) | CNPG, 1 instance, nightly S3 backup + `archive_timeout: 60s` PITR (`database/` Application — deployed now) |
| SMTP | Mailpit (`mailpit.yaml`), no real credentials needed | Real SMTP credentials, sealed |
| Secrets | **No SealedSecrets at all** — `gami-postgres-app` (DB credentials) and `gami-secrets` (`NEXTAUTH_SECRET`) are generated on the cluster by Ansible's `app_secrets` role, generate-once, never in git. No `gami-smtp` either (Mailpit) | `overlays/production/webapp/sealed-secrets/` — `gami-secrets.yaml` + `gami-smtp.yaml`, independently generated, never shared with staging |

Both share `generatorOptions.disableNameSuffixHash: true` — without it,
Kustomize's default hash-suffixed ConfigMap name breaks every
`envFrom.configMapRef` in the Deployment/Job, which 404s at apply time (this
was verified against a real `kubectl kustomize` render, not assumed). The
trade-off: pods don't auto-restart when `gami-config` content changes — bump
a pod-template annotation manually when that matters.

`sealed-secrets/` starts as an **empty** `resources: []` Kustomization in
git — it's populated the first time an operator runs the secrets bootstrap
runbook (see each environment's README "Secrets" section) and never holds
plaintext. Because staging and production each run their own independent
Sealed Secrets controller with its own keypair now (see `cluster-operators/`
below), a SealedSecret sealed against one cluster's controller is
permanently undecryptable against the other's — there's no cross-cluster
reuse possible even by accident.

### `cluster-wide/` — resources shared by every environment

Currently just `cert-manager/cluster-issuers.yaml` — two `ClusterIssuer`
resources (`letsencrypt-staging`, `letsencrypt-production`). These are
**cluster-scoped** Kubernetes resources, which is why they live outside
`base/`: `base/kustomization.yaml` sets a `namespace:`, and Kustomize's
namespace transformer would incorrectly stamp that onto a `ClusterIssuer`
(verified against a real render). `cluster-wide/kustomization.yaml`
deliberately has no `namespace:` field. Since staging and production are now
two fully separate clusters, each needs its own cert-manager +
`ClusterIssuer`s independently — that's why `argocd/` applies this same
source path twice, once per cluster (`app-gami-cluster-wide-staging.yaml`
locally, `app-gami-cluster-wide-production.yaml` against the registered
remote), rather than once for a single shared cluster the way it used to.

### `cluster-operators/` — third-party operators, GitOps-managed

Third-party Kubernetes operators the app manifests depend on — cert-manager
(for `ClusterIssuer`/`Certificate`), the CloudNativePG operator (for the
`Cluster` CRD `overlays/production/database/postgres-cluster.yaml` uses —
**production only**, staging's Postgres is a plain Deployment), the CNPG
Barman Cloud plugin (production's S3 backup only — see
`overlays/production/database/README-backup.md`), and the Sealed Secrets
controller (decrypts each overlay's `sealed-secrets/*.yaml` into real
`Secret`s). Every Postgres PVC on both clusters uses k3s's own bundled
`local-path` storage class — no separate storage operator needed.

**These are installed the same way as everything else in this repo: as
ArgoCD `Application`s, not as a manual `kubectl apply` step or a separate
Ansible role.** Each subdirectory under `cluster-operators/` (not counting
`apps-staging/`/`apps-production/`, see below) is a Kustomization
referencing the operator's official release manifest directly, pinned to an
exact version — bumping the version is a one-line URL change in git,
reviewable as a normal diff. **These leaf directories are unchanged and
shared by both clusters** — only the layer above them (which Application
manifests point at which cluster) forked when staging and production split
apart:

| Path | Installs |
|---|---|
| `cert-manager/kustomization.yaml` | cert-manager v1.21.0 |
| `cnpg/kustomization.yaml` | CloudNativePG operator v1.30.0. **Needs `ServerSideApply=true`** in the Application's `syncOptions` — its `clusters.postgresql.cnpg.io`/`poolers.postgresql.cnpg.io` CRDs exceed Kubernetes' 262144-byte last-applied-configuration annotation limit for client-side apply (confirmed by hand: plain `kubectl apply` fails with `metadata.annotations: Too long`) |
| `cnpg-barman-plugin/kustomization.yaml` | Barman Cloud CNPG-I plugin v0.13.0 — only referenced by `apps-production/`, since staging has no backup; depends on both cert-manager (its own mTLS cert/issuer) and the CNPG operator's CRDs already existing |
| `sealed-secrets/kustomization.yaml` | Bitnami Sealed Secrets controller v0.38.4. **Lands in `kube-system`, not its own namespace** — the upstream `controller.yaml` hardcodes that namespace on every resource it defines, so the Application's `destination.namespace` has no effect here. `kubeseal --fetch-cert` needs `--controller-namespace kube-system --controller-name sealed-secrets-controller` (the full name, not the shorter `sealed-secrets` some docs assume) to match. Staging's and production's installs are two fully separate controllers with two separate keypairs |
| `apps-staging/` | Child ArgoCD `Application` manifests installing **only cert-manager** onto staging — no CNPG (its Postgres is a plain Deployment), no Barman plugin (no backup), no sealed-secrets (its Secrets are Ansible-generated on the cluster) |
| `apps-production/` | Same three, plus the Barman plugin, installed onto **production** via the registered remote cluster |

**Ordering, and why each is an App-of-Apps, not flat Applications**:
cert-manager, the CNPG operator, and Sealed Secrets have no dependency on
each other, but production's Barman plugin needs both cert-manager *and*
CNPG already up (it issues its own mTLS cert via cert-manager and registers
with the CNPG operator during install). `argocd.argoproj.io/sync-wave` is
the mechanism for that — **but it's only honored when a sync operation is
placing a resource into ordered waves. On a standalone, directly-applied
Application, the annotation is inert** (verified against ArgoCD's own docs
and maintainer guidance). The fix is nesting: `argocd/app-cluster-operators-staging.yaml`
and `app-cluster-operators-production.yaml` are each a parent Application
whose "manifests" are the child Applications in `cluster-operators/apps-staging/`
and `apps-production/` respectively (cert-manager/cnpg/sealed-secrets at
wave `"0"`; production's `cnpg-barman-plugin` at wave `"1"`). It's the
**parent's own sync operation** that enforces "wave 0 fully Synced+Healthy
before wave 1 starts."

**A second, unrelated ArgoCD gotcha hit while building this**: ArgoCD
caches rendered manifests in its Redis instance (`argocd-redis`), keyed
independently of the repo-server *process* — restarting `argocd-repo-server`
does **not** reliably bust this cache. Fix: `kubectl exec -n argocd
<redis-pod> -- redis-cli -a <password-from-argocd-redis-secret> FLUSHALL`.
Worth trying this before assuming a sync-wave/hook annotation "isn't being
honored" for some deeper reason — it may just be stale cache.

**Why this replaced a manual step**: earlier, these operators were
documented (in `.claude/plans/infrastructure-cicd-plan.md`'s Rollout Order)
as something a human installs by hand, once, outside of Ansible or ArgoCD.
Moving the install itself into GitOps means it's no longer possible to
forget: it happens automatically the same way the app's own Kustomize
manifests do, and `selfHeal: true` means it can't be accidentally
uninstalled either.

### `argocd/` — what ArgoCD watches

Seven `Application` manifests, split by which cluster each targets — two of
them (`app-cluster-operators-*`) are parents whose own "resources" are more
child Applications defined under `cluster-operators/apps-{staging,production}/`
(see above). Applied during cluster bootstrap by the `argocd` Ansible role
— the local-destination ones directly, the `prod`-destination ones via
`register-remote-cluster.yml` once production is registered — and then
self-managing from there (`syncPolicy.automated` with `prune: true,
selfHeal: true` — ArgoCD both applies new commits and reverts manual cluster
drift).

| File | Watches path | Destination | In `argocd_local_apps`/`argocd_remote_apps`? |
|---|---|---|---|
| `app-cluster-operators-staging.yaml` | `cluster-operators/apps-staging` | local (`https://kubernetes.default.svc`) | always, local |
| `app-cluster-operators-production.yaml` | `cluster-operators/apps-production` | `name: prod` | always, remote |
| `app-gami-cluster-wide-staging.yaml` | `cluster-wide` | local | always, local |
| `app-gami-cluster-wide-production.yaml` | `cluster-wide` | `name: prod` | always, remote |
| `app-gami-staging.yaml` | `overlays/staging` | local (unchanged from before the split — correct precisely because ArgoCD now runs on staging) | local |
| `app-gami-production-database.yaml` | `overlays/production/database` | `name: prod` | remote |
| `app-gami-production-webapp.yaml` | `overlays/production/webapp` | `name: prod` | **not yet** — add to `argocd_remote_apps` when the app is ready |

Child Applications rendered by the two `app-cluster-operators-*.yaml`
parents (defined in `cluster-operators/apps-staging/` and
`apps-production/`, not directly in `argocd/`):

| File | Watches path | Destination namespace | Sync wave | In staging's set / production's set |
|---|---|---|---|---|
| `cert-manager.yaml` | `cluster-operators/cert-manager` | `cert-manager` | 0 | both |
| `cnpg.yaml` | `cluster-operators/cnpg` | `cnpg-system` | 0 | both |
| `sealed-secrets.yaml` | `cluster-operators/sealed-secrets` | `kube-system` (hardcoded by the upstream manifest, not this field) | 0 | both |
| `cnpg-barman-plugin.yaml` | `cluster-operators/cnpg-barman-plugin` | `cnpg-system` | 1 | production only |

This is the actual GitOps loop: **commit a change to this repo → ArgoCD
notices the diff → applies it to whichever cluster the Application targets.**
There is no separate "deploy" step beyond pushing to `main` (staging/production
image tag bumps are typically automated by `gami-app`'s release workflow, per
the design plan in `.claude/plans/infrastructure-cicd-plan.md`), and — as of
the `cluster-operators/` Applications above — no manual `kubectl apply` step
left for cluster bootstrap either.

### `.claude/plans/infrastructure-cicd-plan.md`

The original design document this repo was scaffolded from — CI/CD pipeline
design (GitHub Actions in the separate `gami-app` repo), the full secrets
bootstrap/rotation runbook, verification checklist, and rollout order. Kept
as a historical record and a deeper reference for *why* things are shaped
this way; it predates the split into two independent clusters (it still
describes the old shared 3-node/dev-staging-production design) — the
environment READMEs are the actionable, current, step-by-step version.

---

## Which guide do I want?

- Setting up a sandbox to learn the stack, test an Ansible change, or
  reproduce a bug without touching real infrastructure → **[README-local.md](README-local.md)**
- Deploying an app change to the shared staging environment for QA, or
  bootstrapping the real infrastructure for the first time →
  **[README-staging.md](README-staging.md)**
- Cutting a production release → **[README-production.md](README-production.md)**
