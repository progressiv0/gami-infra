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
attached to both servers, a second `hcloud_firewall` opening 6443 only to
the `10.10.0.0/24` subnet attached only to `gami-prod`, and a third opening
the ArgoCD UI's NodePort 30443 to `admin_ip_cidr` attached only to
`gami-staging`. **No `hcloud_server` resource should appear.**

If the plan looks right:

```bash
terraform apply
```

Note the outputs (`node_public_ips`, `node_argocd_link_ips`, `node_names`,
`node_envs`) — worth confirming they look sane (2 distinct public IPs
matching what's in `ansible/inventory/production.yml`, the `argocd_link`
IPs matching `.2`/`.3`).

### 3. Bootstrap both clusters + ArgoCD (Ansible)

`inventory/production.yml` sets `ansible_user: ops` — but on a fresh
server, `ops` doesn't exist yet (`node_baseline` is what creates it). The
**very first** run against a new node must connect as `root` instead, and
must pass `ssh_public_key_path` so the role has a key to install onto the
new `ops` user (the same key Terraform put on `root`) — otherwise `ops`
gets created with no key and you're locked out of it:

```bash
cd gami-infra/ansible

ansible-playbook -i inventory/production.yml playbooks/site.yml \
  -e ansible_user=root \
  -e ssh_public_key_path=~/.ssh/id_ed25519.pub
```

Every run after that — once `ops` exists with your key and passwordless
sudo on both nodes — drops both overrides and just uses what
`inventory/production.yml` already declares:

```bash
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

**ArgoCD access after bootstrap**: the UI lives on `gami-staging` only —
there's no ArgoCD instance on `gami-prod` to reach. Traefik serves it on its
own dedicated entrypoint (`roles/argocd/files/traefik-argocd-entrypoint.yaml`),
and since `servicelb` is disabled the pinned **NodePort 30443** is the actual
reachable path, not the entrypoint's own 8443:

```
https://<gami-staging's public IP>:30443
```

That port is opened **only to `TF_VAR_admin_ip_cidr`**, at both layers — the
Hetzner cloud firewall (`terraform/main.tf`'s `argocd_ui` firewall, attached
to staging only) and ufw (`roles/node_baseline/tasks/main.yml`). Two
consequences worth knowing up front:
- If your IP rotates you lose the UI along with SSH, and need a
  `terraform apply` with the new CIDR to get both back.
- Expect a **browser certificate warning**: the IngressRoute has a bare
  `tls: {}` with no cert-manager annotation, so Traefik serves its own
  self-signed cert. That's expected here, not a misconfiguration — the
  connection is still encrypted.

Get the admin password:
```bash
KUBECONFIG=<staging kubeconfig> kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```
If you'd rather not depend on a stable admin IP, the alternative that needs
no firewall opening at all is an SSH tunnel over the port-22 access you
already have — `ssh -L 8080:localhost:30443 ops@<gami-staging IP>`, then
browse `https://localhost:8080`. Putting ArgoCD behind a real hostname +
Let's Encrypt cert on 443 instead would drop the cert warning, but it would
also expose the admin login page to the whole internet — don't do that
without an IP-allowlist middleware and a rotated admin password.

Once logged in, you should see **both** clusters listed under Settings →
Clusters — `in-cluster` (staging, where ArgoCD itself runs) and `prod` (the
registered remote).

### 4. Cluster operators (cert-manager, Sealed Secrets) — automatic, just confirm they came up

Unlike an earlier version of this repo, **none of these are a manual
install step anymore** — `argocd/app-cluster-operators-staging.yaml` and
`app-cluster-operators-production.yaml` (both App-of-Apps parents, see
[README.md](README.md)'s `cluster-operators/` section) apply all of them
automatically as soon as ArgoCD exists and production is registered, since
step 3 above applies both. Just confirm they actually came up:

```bash
# On staging (cert-manager + Sealed Secrets only — staging installs no CNPG,
# see below):
KUBECONFIG=<staging kubeconfig> kubectl get application cluster-operators-staging -n argocd
KUBECONFIG=<staging kubeconfig> kubectl get pods -n cert-manager

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

Staging's Postgres (`overlays/staging/postgres.yaml`) is a **plain,
unmanaged `postgres:18-alpine` Deployment** — deliberately not CNPG. It needs
no HA and has **no backup at all** (a documented, deliberate tradeoff, not an
oversight), so the operator would be pure overhead; production is the only
environment on CNPG. That's why staging's cluster-operators set installs
neither `cnpg` nor the Barman plugin.

The consequence for secrets: nothing generates `gami-postgres-app` here the
way CNPG does for production — Ansible's `app_secrets` role creates it on the
cluster instead (step 6 below), so staging needs no SealedSecrets and doesn't
install the sealed-secrets controller at all. Its data lives on a
`local-path` PVC, which survives pod restarts, redeploys and node reboots,
but not loss of the node itself.

**On production**, Sealed Secrets lands in `kube-system`, not its own
namespace — the upstream `controller.yaml` hardcodes that namespace on every
resource it defines. `kubeseal --fetch-cert` needs `--controller-namespace
kube-system --controller-name sealed-secrets-controller` to match. Always
fetch the cert from the cluster you're actually sealing for; a SealedSecret
sealed against one cluster's keypair is permanently undecryptable against
another's.

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

### 6. Staging's secrets — nothing to do

Staging's two Secrets are generated **on the cluster, automatically**, by
`site.yml`'s `app_secrets` role (step 3 above), so there is no `kubeseal`
step here and no credential in git:

| Secret | Keys | Used by |
|---|---|---|
| `gami-postgres-app` | `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`, `uri` | the Postgres container initialises itself from `POSTGRES_*` via `envFrom`; `gami-webapp`/`gami-migrate` connect using `uri` |
| `gami-secrets` | `NEXTAUTH_SECRET` | `gami-webapp` |

The password is written into `POSTGRES_PASSWORD` and into `uri` from the same
shell variable on the node, so the two copies cannot drift apart, and the
plaintext never reaches the Ansible controller or git.

Both are **generate-once**: the role checks whether each Secret exists and
skips it if so, so re-running `site.yml` never rotates them. That's deliberate
— `POSTGRES_PASSWORD` is only read by initdb on the database's very first
start, so rotating it would leave Postgres on the old password while the app
connects with the new one, and rotating `NEXTAUTH_SECRET` would invalidate
every active session and outstanding magic-link.

To rotate on purpose, delete the Secret and re-run `site.yml` — and for the
database, wipe the PVC too (`kubectl -n gami-staging delete pvc
gami-postgres-data`), since an existing data directory keeps the old
password. Staging has no backup, so treat that as destroying the data.

Because ArgoCD only prunes resources it created itself, these hand-made
Secrets are never touched by a sync — the same reason `ghcr-pull-secret`
(step 5) is safe to create out of band.

Staging therefore runs **no SealedSecrets at all**, which is why its cluster
doesn't install the sealed-secrets controller (see
`cluster-operators/apps-staging/`). Production is different: it still seals
`gami-secrets`/`gami-smtp` into git, and CNPG generates its database
credentials — see [README-production.md](README-production.md).

Institution signing keys are **not** a cluster secret at all — they're
per-institution application data managed in Postgres (`gami-app`'s
`src/lib/institution-keys.ts`), created through the app's own UI/API.

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

This is the day-to-day path once the infrastructure exists, and it is fully
automatic: **push to `gami-app`'s `staging` branch and nothing else is
needed.**

1. `gami-app`'s `release.yml` builds the image and pushes it as
   `ghcr.io/authenticmemory/gami-webapp:staging-<short-sha>` — a unique tag,
   never reused.
2. The same workflow's `bump-staging` job checks out **this** repo, runs
   `kustomize edit set image` in `overlays/staging/`, and commits.
3. ArgoCD (`syncPolicy.automated`) sees the changed tag and syncs.

That commit is what makes the deploy visible to ArgoCD at all — it syncs on a
manifest diff, so the tag has to actually change. **Don't hand-edit the
`images:` tag in `overlays/staging/kustomization.yaml`**; CI owns it and will
overwrite you on the next push.

**What happens on sync, in order:**
1. Postgres (sync-wave -1) comes up and reports Healthy.
2. `gami-migrate` Job (sync-wave 0) runs `npm run db:setup` — the same image
   as the webapp, just a different command — and must complete before
   anything else proceeds. It re-runs on every deploy: the Job carries
   `Replace=true`, and the changed image makes it a new manifest.
3. The `gami-webapp` Deployment rolls out (single pod), gated by its
   readiness probe (`/api/version`).

Confirm what actually landed:
```bash
curl -sk https://staging.authenticmemory.org/api/version
```
`sha` there is the commit the running image was built from.

**Non-image changes** (config, hostnames) — edit
`overlays/staging/kustomization.yaml` directly, commit, push; ArgoCD picks
those up the same way.

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
- `kubectl -n gami-staging get secret gami-postgres-app gami-secrets` returns
  both — if either is missing, re-run `site.yml` (the `app_secrets` role
  creates them and is safe to re-run; it won't rotate existing ones).
- The image tags in `overlays/staging/kustomization.yaml` actually exist in
  `ghcr.io/authenticmemory/*` — a typo'd tag just shows as `ImagePullBackOff`.
- `ghcr-pull-secret` exists in the `gami-staging` namespace specifically —
  it's namespace-scoped, so it won't help if it was only created in `gami`
  (production's namespace, on production's separate cluster).
- Staging's Postgres (`overlays/staging/postgres.yaml`, a plain
  `postgres:18-alpine` Deployment) has **no backup at all** — that's intentional (staging
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

