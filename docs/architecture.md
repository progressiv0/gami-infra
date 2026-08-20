# Architecture

What every piece of this repo is and how they fit together. Read this when
you need to understand *why* something is shaped the way it is; the
environment guides are the actionable step-by-step versions.

---

## Mental model

Three layers, each owned by a different tool:

```
Terraform   → attaches networking/firewalls to 2 pre-existing Hetzner VPS
              nodes (staging, prod) — it never creates, resizes, or
              destroys the servers themselves
Ansible     → configures those 2 nodes: installs k3s independently on each
              (no joining — each node is its own single-node cluster),
              installs the one central ArgoCD instance on staging, and
              registers production with it as a remote cluster
ArgoCD      → runs only on staging, watches THIS repo, and applies the
              Kubernetes manifests in base/ + overlays/ — locally onto
              staging, remotely onto the registered production cluster
```

Terraform and Ansible are how the *clusters* come to exist. Everything under
`base/`, `overlays/`, `cluster-wide/`, and `cluster-operators/` is what
ArgoCD continuously reconciles onto them. You run Terraform/Ansible rarely
(new node, cluster rebuild, OS patching); you change the Kustomize manifests
constantly — that's the day-to-day deploy path.

**One important exception**: the files in `argocd/` are *not* GitOps-managed.
They're applied by Ansible, so editing one and pushing does nothing until you
re-run the relevant play. See [troubleshooting.md](troubleshooting.md).

**No separate backend service.** `gami-app` dropped its old Go backend
(`gami-api`). The Next.js `gami-webapp` is the whole app; crypto operations
run as a local library inside it, not over a network API.

---

## Node topology

**Two pre-existing Hetzner VPS nodes (`cx22`), each its own fully
independent, unjoined k3s cluster** — not one shared HA cluster.

| Node | `env` | Runs |
|---|---|---|
| `gami-staging` | `staging` | k3s, the **one central ArgoCD instance** (manages both clusters), staging's `gami-webapp` + plain Postgres + Mailpit |
| `gami-prod` | `prod` | k3s (completely separate cluster), production's `gami-webapp` + CNPG Postgres — **no ArgoCD here** |

Real public IPs are kept out of this public repo —
`ansible/inventory/production.yml` reads them from `GAMI_STAGING_IP` /
`GAMI_PROD_IP` at run time. [`.env.example`](../.env.example) is the single
list of every environment variable this repo's automation reads.

**Neither node is created by Terraform.** `terraform/main.tf` uses read-only
`data "hcloud_server"` lookups. A `terraform plan` proposing to create,
resize, or destroy a server means something is misconfigured — stop and
investigate. Adding a third server means an entry in
`terraform/variables.tf`'s `nodes` list plus a matching host in the Ansible
inventory.

**Each node bootstraps its own single-node embedded-etcd k3s server.**
`k3s server --cluster-init`, independently, on both. Nothing joins anything;
there's no etcd peer traffic and no two-phase bootstrap/join logic.

**ArgoCD installs once, on staging, and manages production as a registered
remote cluster** — ArgoCD's standard multi-cluster pattern. Staging's
Applications use `destination.server: https://kubernetes.default.svc`;
production's use `destination.name: prod`. Registration is a Secret in the
`argocd` namespace labeled `argocd.argoproj.io/secret-type: cluster`, created
by [`register-remote-cluster.yml`](../ansible/roles/argocd/tasks/register-remote-cluster.yml),
which:

1. Creates an `argocd-manager` ServiceAccount + `cluster-admin`
   ClusterRoleBinding on the **prod** node (delegated over SSH).
2. Requests and reads back its ServiceAccount token (k3s 1.24+ doesn't
   auto-create one).
3. Applies the resulting cluster-registration Secret to **staging's** ArgoCD.

This keeps production's node clean — no ArgoCD control-plane pods competing
with the real workload.

**Networking**: no general shared private network between the nodes. A
dedicated one (`gami-argocd-link`, `10.10.0.0/24`, staging `10.10.0.2`, prod
`10.10.0.3`) exists solely so staging's ArgoCD can reach prod's k3s API on
6443 — prod's firewall opens 6443 only to that subnet. SSH (22) and the k3s
API on the public interface are restricted to `admin_ip_cidr`. The ArgoCD UI
(NodePort 30443, staging only) is restricted the same way. 80/443 are the
only genuinely public ports.

Note that k3s bakes its API server certificate SANs at install time — a node
with a private address needs `--tls-san` for it, which
[`cluster-init.yml`](../ansible/roles/k3s_server/tasks/cluster-init.yml)
handles for any host with `argocd_link_ip` set.

**The two environments run different Postgres setups** — see
[database.md](database.md) for the full picture. In short: staging runs a
plain Deployment with no backup (deliberate); production runs CNPG at
`instances: 1` purely for its Barman Cloud backup tooling, with nightly base
backups plus continuous WAL archiving to S3.

All PVCs use k3s's bundled `local-path` storage class — there's no second
node on either cluster for a replicated storage layer to spread across.

**Production's database and webapp are separate ArgoCD Applications**
(`overlays/production/database/` and `overlays/production/webapp/`), so the
database could deploy ahead of the app. Neither has a node-loss HA story:
one node, `replicas: 1`, no podAntiAffinity. A pod crash gets Kubernetes'
normal restart; losing the node takes the environment down.

---

## Repository layout

```
gami-infra/
├── terraform/          Networking/firewall attachment for 2 pre-existing Hetzner nodes
├── ansible/            Cluster bootstrap + day-2 ops (both nodes, independently)
├── base/               Kustomize base: the app's actual Kubernetes resources
├── overlays/
│   ├── staging/          Overlay + plain Postgres (no backup) + Mailpit + GPR store
│   └── production/
│       ├── database/       CNPG Postgres + S3 backup + PITR — own Application
│       └── webapp/         gami-webapp/gami-migrate — own Application
├── cluster-wide/       Cluster-scoped resources, synced onto EACH cluster
├── cluster-operators/  Third-party operators — GitOps-managed, not manual
│   ├── apps-staging/     Child Applications installing operators onto staging
│   └── apps-production/  Same, onto production, plus the Barman plugin
├── argocd/             ArgoCD Application definitions (applied by ANSIBLE, not GitOps)
└── docs/               This documentation
```

### `terraform/`

Attaches networking and firewall rules to the already-provisioned servers.

| File | Purpose |
|---|---|
| `main.tf` | Read-only `data "hcloud_server"` lookups, the `gami-argocd-link` network + subnet, per-node address pinning, and three firewalls (main 22/6443 admin-only + 80/443 public; argocd-link 6443 scoped to the subnet, prod only; ArgoCD UI 30443, staging only) |
| `variables.tf` | `hcloud_token`, `admin_ip_cidr`, `location`, and `nodes` — the "add a server" list |
| `outputs.tf` | `node_public_ips`, `node_argocd_link_ips`, `node_names`, `node_envs` |
| `backend.tf` | Remote state on Hetzner Object Storage, same bucket as production's Postgres backups under a separate prefix |
| `versions.tf` | Provider pin (`hetznercloud/hcloud ~> 1.45`), Terraform `>= 1.7` |

See [terraform.md](terraform.md).

### `ansible/`

| Path | Purpose |
|---|---|
| `inventory/production.yml` | The real infrastructure — static, hand-maintained. Declares both nodes, their `hcloud_labels.env`, the `env_staging`/`env_prod` groups, and prod's `argocd_link_ip` |
| `inventory/local.yml` | Single-machine local inventory |
| `playbooks/site.yml` | **The bootstrap entrypoint.** Tagged per play — see [setup-server.md](setup-server.md) |
| `playbooks/local.yml` | Single-machine equivalent — see [install-local.md](install-local.md) |
| `playbooks/db-dump.yml`, `db-restore.yml`, `db-backup.yml` | Database operations — see [database.md](database.md) |
| `playbooks/patch-os.yml` | Day-2: rolling OS patch + reboot, one node at a time |
| `playbooks/cleanup-logs.yml` | Day-2: journald vacuum, image prune, pod log cleanup |
| `roles/node_baseline/` | OS hardening: unattended-upgrades, non-root `ops` user, ufw mirroring the Hetzner firewall |
| `roles/k3s_server/` | Installs k3s. Every node runs `--cluster-init` independently |
| `roles/app_secrets/` | Generates staging's `gami-postgres-app` and `gami-secrets` on the cluster. **Generate-once** — see [database.md](database.md) for why rotating breaks things |
| `roles/image_pull_secret/` | Renders and applies `ghcr-pull-secret` to both clusters, from `.env` |
| `roles/argocd/` | Installs ArgoCD on staging, applies Application manifests, registers production |
| `roles/database/` | Dump/restore/backup actions, driven by the `db-*` playbooks |

The `argocd` role does more than apply the install manifest:

- Creates the `argocd` namespace (upstream's manifest doesn't)
- Applies with `--server-side --force-conflicts` — client-side apply chokes
  on the `applicationsets.argoproj.io` CRD, whose schema exceeds Kubernetes'
  262144-byte annotation limit
- Registers this repo's git credentials if `GAMI_INFRA_REPO_TOKEN` is set
- Adds a dedicated Traefik entrypoint for the UI on a separate port from
  80/443, via a k3s `HelmChartConfig`
- Sets `server.insecure: "true"` — **required** when fronting ArgoCD with
  Traefik, or every UI request 404s (protocol-sniffing conflict with
  Traefik's HTTP/2 backend negotiation)
- Applies a Traefik `IngressRoute` bound to that entrypoint
- Patches `argocd-cm` with a custom Ingress health check (Traefik in
  host-network mode never populates `.status.loadBalancer`)
- Then, as a separate play, registers production as a remote cluster

### `base/`

Environment-agnostic Kustomize base. Both overlays start here.

| File | Purpose |
|---|---|
| `gami-webapp/deployment.yaml` | The app. Runs as non-root uid 1000. `command: ["npm", "start"]` overrides the image's ENTRYPOINT, which would otherwise re-run `drizzle-kit push` + seed on every pod start. `/api/version` liveness+readiness — a static 200 that deliberately doesn't touch Postgres |
| `gami-webapp/service.yaml` | ClusterIP |
| `gami-webapp/ingress.yaml` | Traefik Ingress, two Host rules both routing to the same Service — the portal/verifier split happens in the app's own middleware |
| `gami-migrate-job.yaml` | Runs `npm run db:setup` against the same image, different command. Sync-wave `0`, between `gami-config` (`-1`) and the Deployment (`1`). `Replace=true,Force=true` because Jobs are immutable |
| `kustomization.yaml` | Ties it together under `namespace: gami`. Deliberately no ConfigMap generator, Secrets, or Postgres — those are per-environment |

### `overlays/`

| | staging | production |
|---|---|---|
| Namespace | `gami-staging` | `gami` |
| Hostnames | `staging.` / `verify-staging.` | `app.` / `verify.` |
| TLS issuer | `letsencrypt-production` | `letsencrypt-production` |
| Postgres | plain Deployment, no backup | CNPG + S3 backup + PITR |
| SMTP | Mailpit | real SMTP credentials, sealed |
| Secrets | generated on-cluster by Ansible — no SealedSecrets at all | `sealed-secrets/`, independently generated |

Both set `generatorOptions.disableNameSuffixHash: true` — without it,
Kustomize's hash-suffixed ConfigMap name breaks every `envFrom.configMapRef`.
The trade-off: pods don't auto-restart when `gami-config` changes.

Because each cluster runs its own Sealed Secrets controller with its own
keypair, a SealedSecret sealed against one is permanently undecryptable
against the other.

### `cluster-wide/`

`cert-manager/cluster-issuers.yaml` — two `ClusterIssuer`s. These are
cluster-scoped, which is why they live outside `base/`: `base` sets a
`namespace:`, and Kustomize's namespace transformer would incorrectly stamp
it onto them. Since the environments are separate clusters, `argocd/` applies
this same path twice, once per cluster.

### `cluster-operators/`

Third-party operators, installed as ArgoCD Applications rather than by hand.
Each subdirectory is a Kustomization referencing the operator's official
release manifest, pinned to an exact version — bumping is a one-line diff.

| Path | Installs |
|---|---|
| `cert-manager/` | cert-manager v1.21.0 |
| `cnpg/` | CloudNativePG v1.30.0. Needs `ServerSideApply=true` — its CRDs exceed the annotation limit for client-side apply |
| `cnpg-barman-plugin/` | Barman Cloud CNPG-I plugin v0.13.0 — production only. Depends on cert-manager and CNPG's CRDs |
| `sealed-secrets/` | Sealed Secrets v0.38.4. Lands in `kube-system` — the upstream manifest hardcodes it, so `destination.namespace` has no effect |
| `apps-staging/` | Child Applications for staging (cert-manager only) |
| `apps-production/` | Child Applications for production, `-production`-suffixed to avoid name collisions |

**Why App-of-Apps, not flat Applications**: production's Barman plugin needs
both cert-manager and CNPG already up. `argocd.argoproj.io/sync-wave` is the
mechanism — but it's **only honored when a sync operation places a resource
into ordered waves. On a standalone, directly-applied Application it's
inert.** Nesting under a parent is what makes the parent's own sync operation
enforce "wave 0 Healthy before wave 1 starts."

The parents' `destination` must be **local**, not `prod` — `Application` is
an ArgoCD CRD that only exists where ArgoCD runs. The children carry their
own `destination.name: prod`.

### `argocd/`

Application definitions. Applied by the `argocd` Ansible role — the
local-destination ones directly, the `prod`-destination ones via
`register-remote-cluster.yml` — then self-managing (`syncPolicy.automated`
with `prune` and `selfHeal`).

| File | Watches | Destination |
|---|---|---|
| `app-cluster-operators-staging.yaml` | `cluster-operators/apps-staging` | local |
| `app-cluster-operators-production.yaml` | `cluster-operators/apps-production` | local (children target prod) |
| `app-gami-cluster-wide-staging.yaml` | `cluster-wide` | local |
| `app-gami-cluster-wide-production.yaml` | `cluster-wide` | `prod` |
| `app-gami-staging.yaml` | `overlays/staging` | local |
| `app-gami-production-database.yaml` | `overlays/production/database` | `prod` |
| `app-gami-production-webapp.yaml` | `overlays/production/webapp` | `prod` |

Which of these actually get applied is controlled by `argocd_local_apps` /
`argocd_remote_apps` in
[`roles/argocd/defaults/main.yml`](../ansible/roles/argocd/defaults/main.yml).

---

## Related

- [Server setup](setup-server.md) — bootstrapping the real infrastructure
- [Local install](install-local.md) — a sandbox on your own machine
- [Staging](staging.md) / [Production](production.md) — day-to-day deploys
- [Database](database.md) — Postgres, dumps, backups
- [Troubleshooting](troubleshooting.md) — known failures and fixes
