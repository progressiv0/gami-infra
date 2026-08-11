# Staging deployment guide

Deploys staging onto its own independent, single-node k3s cluster (node
`gami-staging`), and — because this cluster is also where the one central
ArgoCD instance lives — bootstrapping staging is also how the **whole
real infrastructure** comes up, production included. Read
[README.md](README.md) first for what each piece actually is, especially
its **"Node topology"** section: staging and production are two fully
separate clusters now, on two pre-existing nodes, not two namespaces on one
shared cluster.

> **Status check before you start**: `terraform/` in this repo is written
> but has **not** been run through `terraform validate`/`plan`/`apply` yet
> (see `terraform/README.md`) — there was no `terraform` binary in the
> environment it was authored in. Treat the Terraform step below like an
> unreviewed first-pass PR: read it, run `terraform plan` and actually look
> at the diff, never `apply` blind the first time. **Pay special attention
> to what the plan proposes touching**: `terraform/main.tf` only reads the
> two servers (`data "hcloud_server"`) and attaches networking/firewalls to
> them — it should never propose creating, resizing, or destroying a
> server. If a plan ever does, something's misconfigured (most likely a
> `nodes` entry in `terraform/variables.tf` whose `name` doesn't exactly
> match the real Hetzner server name) — stop and fix that before applying.
> Everything from the Ansible step onward (k3s, ArgoCD) has been exercised
> end-to-end against a real single-node cluster (see
> [README-local.md](README-local.md)'s gotchas section for what was found
> and fixed doing so) — it's the Terraform networking step specifically
> that's unproven.

If the infrastructure already exists (someone already ran the
Terraform+Ansible bootstrap), skip to [Deploying an app change to
staging](#deploying-an-app-change-to-staging) — that's the day-to-day path
you'll actually use most of the time.

---

## One-time infrastructure bootstrap

Skip this whole section if staging and production are already up — check
with your team, or try pointing `kubectl` at staging's kubeconfig and
running `kubectl get nodes` first. This is done **once for both clusters**
— running staging's bootstrap also brings production's ArgoCD management
online (see step 3 below), so there's no separate "production bootstrap."

### 1. Prerequisites

**Every credential this repo's automation needs is an environment
variable — none of them are committed.** `.env.example` at the repo root
is the single list of all of them (which tool reads each one, and which
ones are optional); copy it to `.env`, fill in real values, and `set -a;
source .env; set +a` before running any `terraform`/`ansible` command
below, rather than exporting each one by hand. The bullets below are the
same list with the reasoning for each:

- A Hetzner Cloud account + API token (`TF_VAR_hcloud_token`), with access
  to the two **already-provisioned** servers `gami-staging` and
  `gami-prod`. Terraform never creates these — see the status check above.
- Their real public IPs (`GAMI_STAGING_IP`, `GAMI_PROD_IP`) — deliberately
  not committed to this public repo (see `ansible/inventory/production.yml`).
- Root (or equivalent) SSH access to both servers already working, from
  however they were originally provisioned — Ansible's `node_baseline` role
  creates the non-root `ops` user (`ansible_user: ops` in
  `ansible/inventory/production.yml`) and installs your key for it on first
  run, but that first connection has to land as `root` (or another
  already-privileged account) using whatever access you already have to
  these pre-existing boxes. If the key you connect with isn't already
  found via ssh-agent/`~/.ssh/config`, point `GAMI_SSH_PRIVATE_KEY_PATH` at
  it explicitly.
- If `gami-infra` (this repo) is a **private** GitHub repo: a fine-grained
  PAT with read-only Contents access (`GAMI_INFRA_REPO_TOKEN`) — ArgoCD
  (which only ever runs on staging) needs it to clone the repo it's
  managing both clusters from. See
  `ansible/roles/argocd/tasks/repo-credentials.yml` — this is the step
  that's easy to forget since it used to be a manual `argocd repo add`
  outside of git; it's now automatic as part of `site.yml`, as long as the
  token is set. Leave unset entirely for a public repo.
- A Hetzner Object Storage bucket named `gami-tfstate` created **out of
  band** — Terraform's S3 backend (`terraform/backend.tf`) won't create its
  own bucket. Also generate Object Storage access keys for it
  (`HETZNER_S3_ACCESS_KEY`/`HETZNER_S3_SECRET_KEY`). (Production's Postgres
  backups reuse this same bucket under a different key prefix — see
  [README-production.md](README-production.md) — nothing extra needed
  here.)
- Your own outbound IP (or CIDR) — `TF_VAR_admin_ip_cidr`, used to restrict
  SSH/k3s-API firewall rules to just you, never `0.0.0.0/0`.
- `terraform` (>= 1.7), `ansible-core`, and `kubectl` installed locally.

### 2. Attach networking and firewalls (Terraform)

With `.env` sourced (step 1 above — this is where `TF_VAR_hcloud_token`,
`TF_VAR_admin_ip_cidr`, `HETZNER_S3_ACCESS_KEY`, `HETZNER_S3_SECRET_KEY`
actually get picked up from):

```bash
cd gami-infra/terraform

terraform init \
  -backend-config="access_key=$HETZNER_S3_ACCESS_KEY" \
  -backend-config="secret_key=$HETZNER_S3_SECRET_KEY"

terraform plan
```

**Read the plan output carefully** before proceeding — this is the
unvalidated-HCL step called out above. Confirm it proposes only: 2
`data "hcloud_server"` reads (no creates), one `hcloud_network` +
`hcloud_network_subnet` for the dedicated `gami-argocd-link` network
(`10.10.0.0/24`), two `hcloud_server_network` attachments pinning
`gami-staging` to `10.10.0.2` and `gami-prod` to `10.10.0.3`, the main
`hcloud_firewall` (22/6443 restricted to `admin_ip_cidr`, 80/443 public)
attached to both servers, and a second `hcloud_firewall` opening 6443 only
to the `10.10.0.0/24` subnet, attached only to `gami-prod`. **No `hcloud_server`
resource should appear.**

If the plan looks right:

```bash
terraform apply
```

Note the outputs (`node_public_ips`, `node_argocd_link_ips`, `node_names`,
`node_envs`) — worth confirming they look sane (2 distinct public IPs
matching what's in `ansible/inventory/production.yml`, the `argocd_link`
IPs matching `.2`/`.3`).

### 3. Bootstrap both clusters + ArgoCD (Ansible)

```bash
cd gami-infra/ansible

ansible-playbook -i inventory/production.yml playbooks/site.yml
```

`inventory/production.yml` is a **static**, hand-maintained file now (not
the old dynamic hcloud-API inventory) — since Terraform no longer owns
these servers via the Hetzner API, it can't label them for dynamic
discovery. Confirm the IPs and `hcloud_labels.env` values in that file
actually match your two servers before running this.

This one playbook run, in order (see [README.md](README.md)'s Ansible
section for exactly what each role does):
1. `node_baseline` on **both** nodes (apt hardening, `ops` user, ufw).
2. `k3s_server` on **both** nodes, **independently** — each just runs
   `k3s server --cluster-init` (single-node embedded etcd). Nothing joins
   anything else; there's no "first node bootstraps, others join" phase
   anymore.
3. ArgoCD install, targeted at `env_staging` only (`run_once: true`) — this
   is the **one central ArgoCD instance**, and it only ever lives on
   staging. As part of this, `tasks/repo-credentials.yml` registers this
   repo's git credentials with ArgoCD if `GAMI_INFRA_REPO_TOKEN` is set
   (skips itself entirely for a public repo) — this used to be a manual
   `argocd repo add` step done outside of git; it isn't anymore.
4. **Register production as a remote cluster in staging's ArgoCD**
   (`tasks_from: register-remote-cluster.yml`, also targeted at
   `env_staging`, delegating the prod-side steps to `gami-prod` over SSH).
   This is what actually brings production's ArgoCD management online — it
   creates an `argocd-manager` ServiceAccount + `cluster-admin`
   ClusterRoleBinding on `gami-prod`, reads back its token and CA cert, and
   applies the resulting cluster-registration Secret to staging's ArgoCD.
   From this point on, `kubectl get secret -n argocd -l
   argocd.argoproj.io/secret-type=cluster` on staging should show a `prod`
   entry.

This step is idempotent — safe to re-run if it fails partway, or if a node
gets added later.

Confirm both nodes came up:
```bash
KUBECONFIG=<staging kubeconfig> kubectl get nodes -L env   # just gami-staging
KUBECONFIG=<prod kubeconfig> kubectl get nodes -L env      # just gami-prod, separately
```
There's no single `kubectl get nodes` that shows both — they're two
completely separate API servers now.

**ArgoCD access after bootstrap**: Traefik exposes it on a NodePort (see
`ansible/roles/argocd/defaults/main.yml`'s `argocd_ingress_port`, default
8443 internally / 30443 as the pinned NodePort) on `gami-staging`'s IP only
— there's no ArgoCD instance on `gami-prod` to reach. Get the admin
password:
```bash
KUBECONFIG=<staging kubeconfig> kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```
For anything beyond one-off checks, put this behind a real hostname +
Let's Encrypt cert (an `Ingress`/`IngressRoute` with
`cert-manager.io/cluster-issuer: letsencrypt-production`) rather than relying
on the raw NodePort long-term. Once logged in, you should see **both**
clusters listed under Settings → Clusters — `in-cluster` (staging, where
ArgoCD itself runs) and `prod` (the registered remote).

### 4. Cluster operators (cert-manager, CNPG, Sealed Secrets) — automatic, just confirm they came up

Unlike an earlier version of this repo, **none of these are a manual
install step anymore** — `argocd/app-cluster-operators-staging.yaml` and
`app-cluster-operators-production.yaml` (both App-of-Apps parents, see
[README.md](README.md)'s `cluster-operators/` section) apply all of them
automatically as soon as ArgoCD exists and production is registered, since
step 3 above applies both. Just confirm they actually came up:

```bash
# On staging:
KUBECONFIG=<staging kubeconfig> kubectl get application cluster-operators-staging -n argocd
KUBECONFIG=<staging kubeconfig> kubectl get pods -n cert-manager
KUBECONFIG=<staging kubeconfig> kubectl get pods -n cnpg-system
KUBECONFIG=<staging kubeconfig> kubectl get pods -n kube-system -l name=sealed-secrets-controller

# On production (separate cluster, separate kubeconfig):
KUBECONFIG=<prod kubeconfig> kubectl get pods -n cert-manager
KUBECONFIG=<prod kubeconfig> kubectl get pods -n cnpg-system
KUBECONFIG=<prod kubeconfig> kubectl get pods -n kube-system -l name=sealed-secrets-controller
# Barman Cloud plugin — production only, staging has no backup:
KUBECONFIG=<prod kubeconfig> kubectl get pods -n cnpg-system -l app.kubernetes.io/name=barman-cloud
```

If they're not there yet, ArgoCD may not have gotten to its first sync —
force it from staging's ArgoCD (it manages both):
```bash
kubectl patch application cluster-operators-staging -n argocd --type merge \
  -p '{"operation":{"sync":{"revision":"HEAD"},"initiatedBy":{"username":"admin"}}}'
kubectl patch application cluster-operators-production -n argocd --type merge \
  -p '{"operation":{"sync":{"revision":"HEAD"},"initiatedBy":{"username":"admin"}}}'
```

Staging's Postgres (`overlays/staging/postgres-cluster.yaml`) **is** CNPG
now — same operator as production, `instances: 1`, but with **no backup at
all** (no `ObjectStore`/`ScheduledBackup`/Barman plugin) — a documented,
deliberate tradeoff, not an oversight. CNPG auto-generates and manages the
`gami-postgres-app` Secret itself; there's no hand-sealing step for it the
way an earlier plain-Postgres-Deployment design needed.

**Sealed Secrets lands in `kube-system`, not its own namespace** — the
upstream `controller.yaml` hardcodes that namespace on every resource it
defines. `kubeseal --fetch-cert` needs `--controller-namespace kube-system
--controller-name sealed-secrets-controller` to match (see the secrets
bootstrap steps below). Staging and production each run their **own**
Sealed Secrets controller with their **own** keypair — a SealedSecret
sealed against one is permanently undecryptable against the other, so
always fetch the cert from the cluster you're actually sealing for.

Traefik does **not** need separate installation — k3s bundles it (that's why
`k3s_disable` in `ansible/roles/k3s_server/defaults/main.yml` disables
`servicelb`, not Traefik).

### 5. Create the image pull secret

```bash
kubectl create secret docker-registry ghcr-pull-secret \
  --namespace gami-staging \
  --docker-server=ghcr.io \
  --docker-username=<github-username> \
  --docker-password=<fine-grained PAT, read:packages only> \
  --docker-email=<email>
```

See `base/README-image-pull-secret.md` for why this is a manual, out-of-band
step rather than a committed manifest (even a sealed one) — it's a
long-lived registry credential, not an app secret with its own rotation
story.

### 6. Seal staging's secrets

Staging needs its **own**, independently-generated secrets — never copy
production's. `gami-webapp` doesn't need much: no separate backend service
exists anymore (see [README.md](README.md)), so the only app secret is
`NEXTAUTH_SECRET`.

```bash
NEXTAUTH_SECRET=$(openssl rand -hex 32)

# Fetch STAGING's own controller's public key (safe from anywhere — encrypt-only)
kubeseal --fetch-cert \
  --controller-namespace kube-system \
  --controller-name sealed-secrets-controller > /tmp/sealed-secrets-cert-staging.pem

# Seal straight into the staging overlay
kubectl create secret generic gami-secrets \
  --namespace gami-staging \
  --from-literal=NEXTAUTH_SECRET="$NEXTAUTH_SECRET" \
  --dry-run=client -o yaml \
  | kubeseal --cert /tmp/sealed-secrets-cert-staging.pem -o yaml \
  > overlays/staging/sealed-secrets/gami-secrets.yaml
```

That's the **only** secret staging needs to hand-seal:
- **No `gami-smtp.yaml`** — staging uses Mailpit (`overlays/staging/mailpit.yaml`)
  as its SMTP catcher (`SMTP_HOST=mailpit`, `SMTP_PORT=1025` in
  `overlays/staging/kustomization.yaml`'s `configMapGenerator`) instead of
  real SMTP credentials. Outbound email (magic-link sign-in, DID-publish
  notices) lands in Mailpit's own store instead of actually being sent
  anywhere — read a captured message with `kubectl port-forward -n
  gami-staging svc/mailpit 8025:8025` and browsing to `localhost:8025`.
  Deliberately not exposed via NodePort/Ingress, since it captures real
  single-use sign-in links.
- **No `gami-postgres-app.yaml`** — staging's Postgres is CNPG
  (`overlays/staging/postgres-cluster.yaml`), which auto-generates and
  manages that Secret itself. There's no plain Deployment here anymore to
  hand-seal one for.

Institution signing keys are **not** a cluster secret at all — they're
per-institution application data managed in Postgres (`gami-app`'s
`src/lib/institution-keys.ts`), created through the app's own UI/API, not
sealed here.

`overlays/staging/sealed-secrets/kustomization.yaml`'s `resources:` list
already just has:

```yaml
resources:
  - gami-secrets.yaml
```

```bash
git add overlays/staging/sealed-secrets/
git commit -m "chore: seal staging secrets"
git push
```

### 7. Apply the ArgoCD Application

If `site.yml`'s `argocd` role already applied `argocd/app-gami-staging.yaml`
(it does, as part of `argocd_local_apps`), staging should already show up
in `kubectl get applications -n argocd`. If not:

```bash
kubectl apply -f argocd/app-gami-staging.yaml
```

Watch it sync:

```bash
kubectl get application gami-staging -n argocd -w
```

`SYNC STATUS` should move from `OutOfSync`/`Unknown` to `Synced`, and
`HEALTH STATUS` to `Healthy` once the migrate Job completes, the CNPG
`Cluster` provisions, Mailpit comes up, and the Deployment comes up.

---

## Deploying an app change to staging

This is the day-to-day path once the infrastructure exists. Staging deploys
are **not** gated behind the same manual release process as production —
bump the image tag directly and push:

```bash
cd overlays/staging
kustomize edit set image \
  ghcr.io/authenticmemory/gami-webapp=ghcr.io/authenticmemory/gami-webapp:<tag> \
  ghcr.io/authenticmemory/gami-webapp-migrate=ghcr.io/authenticmemory/gami-webapp:<tag>-migrate

git add kustomization.yaml
git commit -m "deploy: bump staging to <tag>"
git push
```

ArgoCD (with `syncPolicy.automated`) picks up the commit automatically —
usually within its polling interval, or immediately if you trigger a manual
sync from the ArgoCD UI/CLI. No SSH, no manual `kubectl apply` needed for a
routine image bump.

**What happens on sync, in order:**
1. `gami-migrate` Job (sync-wave 0) runs `npm run db:setup` against the
   `-migrate` image tag — must complete successfully before anything else
   proceeds.
2. The `gami-webapp` Deployment rolls out (single pod), gated by
   its readiness probe (`/api/public/health`).

**Non-image changes** (config, hostnames) — edit
`overlays/staging/kustomization.yaml` directly, commit, push, same
auto-sync applies.

---

## Verifying staging

```bash
kubectl get pods -n gami-staging
kubectl get application gami-staging -n argocd
```

Hit both hostnames from outside the cluster:
```bash
curl -I https://staging.authenticmemory.org
curl -I https://verify-staging.authenticmemory.org
```
Since staging uses `letsencrypt-staging`, expect a certificate warning in a
normal browser (it's real ACME-issued, just from Let's Encrypt's untrusted
staging CA — that's intentional, to avoid burning production's rate limits
while iterating). `curl -I` will still show a `200`/redirect; use `curl -Ik`
if you want to skip the cert warning entirely while checking connectivity.

Confirm the migrate-before-rollout ordering actually held: check that
`gami-migrate` shows `Completed` and has an earlier timestamp than the
current `gami-webapp` pod:
```bash
kubectl get pods -n gami-staging -o wide
```

Confirm the app is actually using Mailpit, not trying (and failing) to
reach a real SMTP server: trigger a magic-link sign-in and check
```bash
kubectl port-forward -n gami-staging svc/mailpit 8025:8025
```
then browse to `localhost:8025` and confirm the message landed there.

---

## Troubleshooting

Most cluster-level issues (clock skew, ArgoCD login looping, Traefik
entrypoint collisions) are the same regardless of which environment you're
looking at — see [README-local.md](README-local.md)'s **Gotchas** section,
which documents exact symptoms and fixes found while building this out.

Staging-specific things to check first:
- `overlays/staging/sealed-secrets/kustomization.yaml` actually lists the
  sealed files you created (easy to forget — the file starts as `resources: []`).
- The image tags in `overlays/staging/kustomization.yaml` actually exist in
  `ghcr.io/authenticmemory/*` — a typo'd tag just shows as `ImagePullBackOff`.
- `ghcr-pull-secret` exists in the `gami-staging` namespace specifically —
  it's namespace-scoped, so it won't help if it was only created in `gami`
  (production's namespace, on production's separate cluster).
- Staging's Postgres (`overlays/staging/postgres-cluster.yaml`, CNPG,
  `instances: 1`) has **no backup at all** — that's intentional (staging
  doesn't need to survive data loss the way production does), not a bug.
  Don't expect it to survive anything worse than a pod restart; if the
  `Cluster` itself gets wedged, see [README-local.md](README-local.md)'s
  CNPG gotcha.
- If production's Applications (`kubectl get applications -n argocd` on
  staging — they show up there too, since staging's ArgoCD manages both)
  are stuck `Unknown`, check that the remote-cluster registration actually
  succeeded: `kubectl get secret -n argocd -l
  argocd.argoproj.io/secret-type=cluster` should show a `prod` entry. If
  it's missing, re-run `site.yml` (idempotent) or the
  `register-remote-cluster.yml` tasks by hand.
