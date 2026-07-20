# Staging deployment guide

Deploys the shared staging environment onto the real 3-node Hetzner k3s
cluster. Dev, staging, and production run on the **same cluster**, in
separate namespaces (`gami-dev`, `gami-staging`, `gami`) — this guide only
covers what's different for staging; read [README.md](README.md) first for
what each piece actually is, especially its **"Node topology"** section
(staging is "home" to its own small node, but that's a scheduling
preference, not a separate cluster).

> **Status check before you start**: `terraform/` in this repo is written
> but has **not** been run through `terraform validate`/`plan`/`apply` yet
> (see `terraform/README.md`) — there was no `terraform` binary in the
> environment it was authored in. Treat the Terraform step below like an
> unreviewed first-pass PR: read it, run `terraform plan` and actually look
> at the diff, never `apply` blind the first time. Everything from the
> Ansible step onward (k3s, ArgoCD) has been exercised end-to-end against a
> real multi-node cluster (see [README-local.md](README-local.md)'s gotchas
> section for what was found and fixed doing so) — it's the Terraform
> provisioning step specifically that's unproven.

If the cluster already exists (someone already ran the Terraform+Ansible
bootstrap), skip to [Deploying an app change to
staging](#deploying-an-app-change-to-staging) — that's the day-to-day path
you'll actually use most of the time.

---

## One-time cluster bootstrap

Skip this whole section if the 3-node cluster is already running — check
with your team, or try `kubectl get nodes` against the existing kubeconfig
first. This is done **once for the whole cluster**, not once per
environment — if dev or production has already bootstrapped it, skip ahead.

### 1. Prerequisites

- A Hetzner Cloud account + API token (`hcloud_token`).
- A Hetzner Object Storage bucket named `gami-tfstate` created **out of
  band** — Terraform's S3 backend (`terraform/backend.tf`) won't create its
  own bucket. Also generate Object Storage access keys for it. (Production's
  Postgres backups reuse this same bucket under a different key prefix —
  see [README-production.md](README-production.md) — nothing extra needed
  here.)
- Your SSH public key (installed on all 3 nodes for the `ops` user).
- Your own outbound IP (or CIDR) — used to restrict SSH/k3s-API firewall
  rules to just you, never `0.0.0.0/0`.
- `terraform` (>= 1.7) and `kubectl` installed locally, or run everything
  via the `workflow_dispatch` GitHub Actions path described in the design
  plan (`.claude/plans/infrastructure-cicd-plan.md`, Phase 5) if you'd
  rather not install Terraform locally.

### 2. Provision the VPS nodes (Terraform)

```bash
cd gami-infra/terraform

terraform init \
  -backend-config="access_key=$HETZNER_S3_ACCESS_KEY" \
  -backend-config="secret_key=$HETZNER_S3_SECRET_KEY"

TF_VAR_hcloud_token="<your Hetzner API token>" \
TF_VAR_admin_ip_cidr="<your IP>/32" \
TF_VAR_ssh_public_key="$(cat ~/.ssh/id_ed25519.pub)" \
  terraform plan
```

**Read the plan output carefully** before proceeding — this is the
unvalidated-HCL step called out above. Look for: 3 `hcloud_server` resources
(`gami-node-dev`, `gami-node-staging`, `gami-node-prod` — different
`server_type` each, per `terraform/variables.tf`'s `nodes` list), one
`hcloud_network` + subnet, one `hcloud_firewall` with the rules described in
[README.md](README.md)'s Terraform section, one `hcloud_ssh_key`. Confirm
each server's `labels` includes both `role=k3s-server` and the right `env`
value (`dev`/`staging`/`prod`) — that `env` label is what Ansible later turns
into a real Kubernetes node label, which the overlays' node
affinity/anti-affinity rules depend on.

If the plan looks right:

```bash
TF_VAR_hcloud_token="..." \
TF_VAR_admin_ip_cidr="<your IP>/32" \
TF_VAR_ssh_public_key="$(cat ~/.ssh/id_ed25519.pub)" \
  terraform apply
```

Per the design plan, `terraform apply` is meant to run from a GitHub Actions
`workflow_dispatch` job (gated, manual-trigger, audit-trailed) rather than
routinely from a laptop — set that up if it doesn't already exist, otherwise
running it locally as above works too, just without the audit trail.

Note the outputs (`node_public_ips`, `node_private_ips`, `node_names`,
`node_envs`) — Ansible's dynamic inventory (`inventory/hcloud.yml`) sources
these live from the Hetzner API via the `role=k3s-server` label and
`keyed_groups` on the `env` label, so you don't need to manually copy IPs
anywhere, but it's worth confirming they look sane (3 distinct IPs, correct
`env` per node, matching the region you expected).

### 3. Bootstrap k3s + ArgoCD (Ansible)

```bash
cd gami-infra/ansible

# The dynamic inventory needs the hetzner.hcloud collection and your token:
ansible-galaxy collection install hetzner.hcloud
export HCLOUD_TOKEN="<same token as above>"

ansible-playbook -i inventory/hcloud.yml playbooks/site.yml
```

This is the real production-shaped bootstrap (see [README.md](README.md)'s
Ansible section for exactly what each role does): `node-baseline` on all 3
nodes, then the first node (alphabetically first by name — deterministic
regardless of inventory ordering) runs `k3s --cluster-init`, then the other
2 join it — every node also gets `--node-label env=<its env>` at install
time. All 3 run the k3s **server** role — that's the HA design; losing any
single node still leaves a 2-of-3 etcd quorum, regardless of which
environment each node is "home" to.

This step is idempotent — safe to re-run if it fails partway or if a node
gets added later.

Confirm the node labels landed:
```bash
kubectl get nodes -L env
```
Should show `dev`, `staging`, `prod` (one each) in the `ENV` column.

**ArgoCD access after bootstrap**: same as local — Traefik exposes it on a
NodePort (see `ansible/roles/argocd/defaults/main.yml`'s `argocd_ingress_port`,
default 8443 internally / 30443 as the pinned NodePort) on every node's
private IP. ArgoCD itself is scheduled with a preference for the `env=dev`
node (it's cluster-wide infra riding on the small box). Get the admin
password:
```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```
For anything beyond one-off checks, put this behind a real hostname +
Let's Encrypt cert (an `Ingress`/`IngressRoute` with
`cert-manager.io/cluster-issuer: letsencrypt-production`) rather than relying
on the raw NodePort long-term.

### 4. Cluster operators (cert-manager, CNPG, Longhorn) — automatic, just confirm they came up

Unlike an earlier version of this repo, **cert-manager, the CloudNativePG
operator, and Longhorn are no longer a manual install step** —
`argocd/app-cluster-operators.yaml` (an App-of-Apps parent, see
[README.md](README.md)'s `cluster-operators/` section) applies them
automatically as soon as ArgoCD itself exists, since `site.yml`'s `argocd`
role applies every file in `argocd/` including this one. Just confirm they
actually came up before moving on — if the underlying `kubectl apply -f
argocd/` step in `site.yml` ran, these should already be `Synced`/`Healthy`:

```bash
kubectl get application cluster-operators -n argocd
# or, since the children aren't labeled that way by default, just:
kubectl get pods -n cert-manager
kubectl get pods -n cnpg-system
kubectl get pods -n longhorn-system
kubectl get storageclass longhorn
```

If they're not there yet, ArgoCD may not have gotten to its first sync —
force it:
```bash
kubectl patch application cluster-operators -n argocd --type merge \
  -p '{"operation":{"sync":{"revision":"HEAD"},"initiatedBy":{"username":"admin"}}}'
```

**Longhorn needs `open-iscsi` + a running `iscsid` service on every node**
before its PVCs can actually bind — `ansible/roles/node-baseline/tasks/main.yml`
installs this, so it should already be true if `site.yml` ran the full
`node-baseline` role. If a Postgres PVC sits `Pending` with `unbound
immediate PersistentVolumeClaims`, check `systemctl status iscsid` on each
node before assuming it's a Longhorn manifest problem.

**One thing this repo still doesn't automate**: the **Sealed Secrets
controller** (bitnami-labs) — needed before any `SealedSecret` in
`overlays/*/sealed-secrets/` can be decrypted into a real `Secret`. Install
this separately, the same manual way as before.

Traefik does **not** need separate installation — k3s bundles it (that's why
`k3s_disable` in `ansible/roles/k3s-server/defaults/main.yml` disables
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
dev's or production's. `gami-webapp` doesn't need much: no separate backend
service exists anymore (see [README.md](README.md)), so the only app secret
is `NEXTAUTH_SECRET`.

```bash
NEXTAUTH_SECRET=$(openssl rand -hex 32)

# Fetch the cluster's public key (safe from anywhere — encrypt-only)
kubeseal --fetch-cert \
  --controller-namespace kube-system \
  --controller-name sealed-secrets > /tmp/sealed-secrets-cert.pem

# Seal straight into the staging overlay
kubectl create secret generic gami-secrets \
  --namespace gami-staging \
  --from-literal=NEXTAUTH_SECRET="$NEXTAUTH_SECRET" \
  --dry-run=client -o yaml \
  | kubeseal --cert /tmp/sealed-secrets-cert.pem -o yaml \
  > overlays/staging/sealed-secrets/gami-secrets.yaml

# SMTP — real values from your email provider, provided out of band
kubectl create secret generic gami-smtp \
  --namespace gami-staging \
  --from-literal=SMTP_USER="<real SMTP username>" \
  --from-literal=SMTP_PASS="<real SMTP password>" \
  --dry-run=client -o yaml \
  | kubeseal --cert /tmp/sealed-secrets-cert.pem -o yaml \
  > overlays/staging/sealed-secrets/gami-smtp.yaml
```

Institution signing keys are **not** a cluster secret at all — they're
per-institution application data managed in Postgres (`gami-app`'s
`src/lib/institution-keys.ts`), created through the app's own UI/API, not
sealed here.

Then add both filenames to `overlays/staging/sealed-secrets/kustomization.yaml`'s
`resources:` list (it starts empty), commit, and push:

```yaml
resources:
  - gami-secrets.yaml
  - gami-smtp.yaml
```

```bash
git add overlays/staging/sealed-secrets/
git commit -m "chore: seal staging secrets"
git push
```

### 7. Apply the ArgoCD Application

If `site.yml`'s `argocd` role already applied `argocd/app-gami-staging.yaml`
(it does, as part of `argocd/*.yaml`), staging should already show up in
`kubectl get applications -n argocd`. If not, or if you're adding staging to
an existing cluster that only had other environments before:

```bash
kubectl apply -f argocd/app-gami-staging.yaml
```

Watch it sync:

```bash
kubectl get application gami-staging -n argocd -w
```

`SYNC STATUS` should move from `OutOfSync`/`Unknown` to `Synced`, and
`HEALTH STATUS` to `Healthy` once the migrate Job completes, the CNPG
`Cluster` provisions, and the Deployment comes up.

---

## Deploying an app change to staging

This is the day-to-day path once the cluster exists. Staging deploys are
**not** gated behind the same manual release process as production — bump
the image tag directly and push:

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
1. `gami-migrate` Job (PreSync hook) runs `npm run db:setup` against the
   `-migrate` image tag — must complete successfully before anything else
   proceeds.
2. The `gami-webapp` Deployment rolls out (single pod for staging), gated by
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

Confirm the pod actually landed on the staging node (soft preference, so
check it's actually being honored, not just hoped for):
```bash
kubectl get pods -n gami-staging -o wide
kubectl get nodes -L env
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
  (production's) or `gami-dev`.
- Staging's Postgres (`overlays/staging/postgres-cluster.yaml`) is a
  **single instance with no backup** — that's intentional (staging doesn't
  need high reliability), not a bug. Don't expect it to survive losing the
  staging node; just re-sync if that happens.
