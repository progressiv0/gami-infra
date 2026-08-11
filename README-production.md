# Production deployment guide

Deploys production onto its **own independent, single-node k3s cluster**
(node `gami-prod`) — a fully separate cluster from staging's, not a
namespace on a shared one. Read [README.md](README.md) first for what each
piece is — especially its **"Node topology"** section: production no
longer has any node-loss HA story (there's only one node), but it does have
real, improved database durability via point-in-time recovery (PITR),
covered below.

**There is no ArgoCD instance on production's own node.** ArgoCD installs
once, on staging, and manages production as a **registered remote
cluster** — the standard ArgoCD multi-cluster pattern. Practically, this
means:
- Production's ArgoCD Application manifests
  (`app-gami-production-database.yaml`, `app-gami-production-webapp.yaml`,
  `app-cluster-operators-production.yaml`, `app-gami-cluster-wide-production.yaml`)
  all use `destination.name: prod` instead of `destination.server:
  https://kubernetes.default.svc`.
- The whole cluster gets brought under ArgoCD's management as part of
  **staging's** `site.yml` run (`register-remote-cluster.yml` — creates an
  `argocd-manager` ServiceAccount/ClusterRoleBinding on `gami-prod`,
  reads its token, and registers it with staging's ArgoCD), not by running
  anything directly against a production ArgoCD, because there isn't one.
- Watching or forcing a sync for a production Application means pointing
  `kubectl`/the ArgoCD UI at **staging's** ArgoCD (it manages both
  clusters), not at production's own kubeconfig — production's own
  kubeconfig is for the workloads themselves (`kubectl get pods -n gami`,
  etc.), not for ArgoCD operations.

**Production is split into two separate ArgoCD Applications**:
`overlays/production/database/` (CNPG Postgres + S3 backup + PITR) and
`overlays/production/webapp/` (`gami-webapp`/`gami-migrate`). The database
is deployed now, ahead of the web app, since the app's own branches/images
aren't ready yet — `argocd_remote_apps` (`ansible/roles/argocd/defaults/main.yml`)
includes `app-gami-production-database.yaml` but deliberately **not**
`app-gami-production-webapp.yaml` yet. Everything below that's specific to
`gami-webapp`/`gami-migrate` (release process, secrets, verifying a
deploy) doesn't apply until that's added — it's here for when it is.

Read [README-staging.md](README-staging.md) too if the infrastructure
doesn't exist yet — **bootstrap (Terraform + Ansible + operator installs,
for BOTH clusters) is done once, via staging's runbook, not once per
environment.** If staging is already running, production is either already
registered too (one `site.yml` run does both) or just needs its own
Application(s) applied — see below.

> **Status check**: `terraform/` has not been run through `terraform
> plan`/`apply` against real infrastructure yet (see `terraform/README.md`
> and [README-staging.md](README-staging.md)'s callout). If you're standing
> up the infrastructure for the first time, do that validation via staging's
> runbook first — don't let production be the first real test of unreviewed
> Terraform. Also remember: Terraform can never create, resize, or destroy
> `gami-prod` itself — only attach networking/firewalls to it (it already
> exists in Hetzner). A plan proposing to touch the server is a red flag,
> not a normal diff.

---

## Prerequisites (if the infrastructure doesn't exist yet)

Identical to staging's prerequisites — one bootstrap run
(`ansible-playbook -i inventory/production.yml playbooks/site.yml`, from
staging's node/context) brings up both clusters and registers production
with staging's ArgoCD. Follow [README-staging.md](README-staging.md)'s
**One-time infrastructure bootstrap** section in full (Terraform networking,
Ansible k3s+ArgoCD bootstrap — cert-manager, CloudNativePG, and the Sealed
Secrets controller all install themselves automatically via ArgoCD once
that's done, see [README.md](README.md)'s `cluster-operators/` section).
Come back here once that's done.

Also confirm the **Barman Cloud plugin** specifically came up on
production — it's the one piece of `cluster-operators/` that only
production needs (staging has no backup):
```bash
KUBECONFIG=<prod kubeconfig> kubectl get pods -n cnpg-system -l app.kubernetes.io/name=barman-cloud
```
See [overlays/production/database/README-backup.md](overlays/production/database/README-backup.md)
for what depends on it.

The only production-specific one-time steps are below. All `kubectl`
commands below target production's **own** kubeconfig (the workloads
themselves), not staging's — see the ArgoCD note above.

### Image pull secret (production namespace)

```bash
kubectl create secret docker-registry ghcr-pull-secret \
  --namespace gami \
  --docker-server=ghcr.io \
  --docker-username=<github-username> \
  --docker-password=<fine-grained PAT, read:packages only> \
  --docker-email=<email>
```

### Seal production's secrets

**Never reuse staging's secrets here** — production has its own,
independently-generated values, sealed against production's own Sealed
Secrets controller (a separate keypair from staging's; see
[README.md](README.md)'s `overlays/` section). There's no separate backend
service anymore (`gami-app` dropped it — see [README.md](README.md)), so
the app secret surface is small: just `NEXTAUTH_SECRET` and SMTP
credentials.

```bash
NEXTAUTH_SECRET=$(openssl rand -hex 32)

kubeseal --fetch-cert \
  --controller-namespace kube-system \
  --controller-name sealed-secrets-controller > /tmp/sealed-secrets-cert-prod.pem

kubectl create secret generic gami-secrets \
  --namespace gami \
  --from-literal=NEXTAUTH_SECRET="$NEXTAUTH_SECRET" \
  --dry-run=client -o yaml \
  | kubeseal --cert /tmp/sealed-secrets-cert-prod.pem -o yaml \
  > overlays/production/webapp/sealed-secrets/gami-secrets.yaml

# Real SMTP credential from your email provider — production uses a real
# SMTP relay, unlike staging's Mailpit catcher
kubectl create secret generic gami-smtp \
  --namespace gami \
  --from-literal=SMTP_USER="<real SMTP username>" \
  --from-literal=SMTP_PASS="<real SMTP password>" \
  --dry-run=client -o yaml \
  | kubeseal --cert /tmp/sealed-secrets-cert-prod.pem -o yaml \
  > overlays/production/webapp/sealed-secrets/gami-smtp.yaml
```

No `gami-signing-key` secret — institution signing keys are per-institution
application data managed in Postgres (`gami-app`'s
`src/lib/institution-keys.ts`), created through the app's own admin UI/API,
not sealed at the infra level.

Add the filenames to `overlays/production/webapp/sealed-secrets/kustomization.yaml`
(starts as `resources: []`):

```yaml
resources:
  - gami-secrets.yaml
  - gami-smtp.yaml
```

```bash
git add overlays/production/webapp/sealed-secrets/
git commit -m "chore: seal production secrets"
git push
```

**Before the first real deploy**, also replace the SMTP placeholder values
baked into `overlays/production/webapp/kustomization.yaml`'s
`configMapGenerator` (`SMTP_HOST=smtp.example.com` etc. are literally
placeholders in the committed file) with real values.

### Set up production Postgres backups (nightly + PITR)

Production is the **only** environment that backs up to S3 (staging
deliberately doesn't — see [README.md](README.md)'s "Node topology"
section). This isn't just a nightly snapshot: `postgres-cluster.yaml` also
sets `postgresql.parameters.archive_timeout: "60s"`, which forces
continuous WAL archiving to S3 on a timer instead of only when a segment
fills — that's what gives production true point-in-time recovery (recover
to a specific timestamp, not just "restore last night's backup"), bounding
data loss to roughly a minute even for an in-flight batch job. Full setup
steps, the on-demand backup command, and how to verify a restore actually
works are in
[overlays/production/database/README-backup.md](overlays/production/database/README-backup.md)
— do this before your first real production sync, not after. This
includes creating the `gami-prod-backup` Object Storage bucket (shared with
Terraform's own state, under a separate key prefix — see
`terraform/backend.tf`'s comment) and the `gami-postgres-backup-creds`
Secret.

### Apply the production database Application

This is the part that's actually deployed today — `gami-webapp`/
`gami-migrate` (`app-gami-production-webapp.yaml`) come later, see the intro
above. Since production's Applications target the registered remote
cluster, apply this **from wherever you'd normally run `kubectl` against
staging's ArgoCD** (it's the one managing the sync), not from production's
own kubeconfig:

```bash
kubectl apply -f argocd/app-gami-production-database.yaml   # against staging's ArgoCD API
kubectl get application gami-production-database -n argocd -w
```

Watch for the CNPG `Cluster` (`overlays/production/database/postgres-cluster.yaml`)
to provision its single instance, and the `ObjectStore`/`ScheduledBackup` to
come up healthy — these checks run against **production's own** kubeconfig,
since that's where the actual resources land:
```bash
KUBECONFIG=<prod kubeconfig> kubectl get cluster gami-postgres -n gami
KUBECONFIG=<prod kubeconfig> kubectl get objectstore -n gami
KUBECONFIG=<prod kubeconfig> kubectl get scheduledbackup -n gami
```

### Later: bring the web app online

Once `gami-app`'s branches/images are ready:
1. Complete the secrets bootstrap above (`gami-secrets`/`gami-smtp`) and the
   image pull secret, if not already done.
2. Add `app-gami-production-webapp.yaml` to `argocd_remote_apps` in
   `ansible/roles/argocd/defaults/main.yml`, commit, push.
3. Re-run `site.yml`'s ArgoCD registration step (or `kubectl apply -f
   argocd/app-gami-production-webapp.yaml` directly against staging's
   ArgoCD, for an immediate test).
4. Continue with "Deploying a production release" below.

---

## Deploying a production release

Unlike staging, production deploys are meant to go through a **gated,
auditable release process** — cutting a GitHub Release on the `gami-app`
repo, not editing this repo's image tags directly by hand. (Per the design
plan: "push to `main` never deploys; cutting a release does.") The intended
flow, end to end:

1. **Cut a GitHub Release** on `authenticmemory/gami-app` (manual trigger).
2. Its `release.yml` workflow builds the `gami-webapp` image, pushes it to
   `ghcr.io/authenticmemory/gami-webapp` tagged with the release version,
   plus a second `-migrate` tagged image (the builder stage with
   npm/drizzle-kit/tsx — the runtime image is distroless and doesn't have
   these tools).
3. That same workflow checks out **this repo** (`gami-infra`) using a
   scoped `INFRA_REPO_TOKEN`, runs `kustomize edit set image` inside
   `overlays/production/webapp/`, commits, and pushes.
4. ArgoCD (watching `overlays/production/webapp` via
   `argocd/app-gami-production-webapp.yaml`, against the registered `prod`
   cluster) detects the diff and syncs.
5. `gami-migrate` (sync-wave `0`) runs to completion before `gami-webapp`
   (sync-wave `1`) rolls out — plain `argocd.argoproj.io/sync-wave`
   ordering, not a PreSync hook (see `base/gami-migrate-job.yaml`'s own
   comment for why: an earlier PreSync-hook version of this Job could never
   see `gami-config`, since hooks run in a phase that completes entirely
   before any Sync-phase resource is even attempted).
6. k3s performs a rolling update, one pod at a time, gated by the readiness
   probe. `gami-webapp` runs a single replica on production's one node — no
   podAntiAffinity, no node-spread; a pod crash gets Kubernetes' normal
   restart, but losing the node itself takes production down until it's
   back (see [README.md](README.md)'s "Node topology" section for why that
   trade was made).

**If `release.yml` doesn't exist yet in `gami-app`**, or you need to deploy
manually as a one-off before that automation is wired up, do the equivalent
by hand:

```bash
cd gami-infra/overlays/production/webapp
kustomize edit set image \
  ghcr.io/authenticmemory/gami-webapp=ghcr.io/authenticmemory/gami-webapp:<release-tag> \
  ghcr.io/authenticmemory/gami-webapp-migrate=ghcr.io/authenticmemory/gami-webapp:<release-tag>-migrate

git add kustomization.yaml
git commit -m "deploy: release <release-tag> to production"
git push
```

ArgoCD picks it up the same way either path.

**Do not** treat a plain push to `main` (without a release tag) as a
deploy signal for production — per the design intent, only a cut release
should move production's image tags.

---

## Verifying a production deploy

```bash
KUBECONFIG=<prod kubeconfig> kubectl get pods -n gami -o wide
kubectl get application gami-production-webapp -n argocd   # against staging's ArgoCD
```

```bash
curl -I https://app.authenticmemory.org
curl -I https://verify.authenticmemory.org
```

Both should return a real, browser-trusted certificate
(`letsencrypt-production`, not the staging ACME endpoint) — check with your
browser directly, or `openssl s_client -connect app.authenticmemory.org:443
-servername app.authenticmemory.org </dev/null 2>/dev/null | openssl x509
-noout -issuer` and confirm the issuer is Let's Encrypt's real production
CA, not `(STAGING)`.

Confirm the migrate-before-rollout ordering held (same check as staging):
```bash
KUBECONFIG=<prod kubeconfig> kubectl get pods -n gami -o wide
```
`gami-migrate` should show `Completed`, timestamped before the current
`gami-webapp` pod.

**Rolling update sanity check**: watch a deploy in progress —
```bash
KUBECONFIG=<prod kubeconfig> kubectl rollout status deployment/gami-webapp -n gami
```
Confirm zero downtime by hitting the health endpoint in a loop from another
terminal while the rollout runs:
```bash
while true; do curl -s -o /dev/null -w "%{http_code}\n" https://app.authenticmemory.org/api/public/health; sleep 1; done
```

---

## Point-in-time recovery verification (worth doing at least once, not just after every deploy)

Production's single-node cluster has no node-loss HA to verify anymore —
there's only one node, so the old "kill a node, confirm pods reschedule
elsewhere" and "kill the Postgres primary, confirm CNPG promotes a replica"
checks no longer apply (there's no second node or replica to fail over to).
What replaced that as production's actual durability story is **backup +
point-in-time recovery** — verify that properly, in a maintenance window,
not casually against live data:

- **Nightly `ScheduledBackup` ran and succeeded**:
  ```bash
  KUBECONFIG=<prod kubeconfig> kubectl get scheduledbackup gami-postgres-nightly -n gami
  KUBECONFIG=<prod kubeconfig> kubectl get backup -n gami
  ```
  Confirm the most recent `Backup` shows `phase: completed`, not just that
  the `ScheduledBackup` object exists.
- **WAL is actually landing in S3 continuously, not just nightly** — this
  is what `archive_timeout: 60s` is supposed to guarantee. Check the
  `gami-postgres-1` pod's logs around WAL archiving, or list the backup
  bucket's WAL prefix and confirm new objects appear roughly every 60
  seconds during active write traffic, not only once a night:
  ```bash
  KUBECONFIG=<prod kubeconfig> kubectl logs -n gami gami-postgres-1 -c postgres | grep -i archive
  ```
- **Run an actual restore drill that proves PITR, not just "restore the
  latest nightly snapshot"**: run a test transaction (insert a
  recognizable row), note the wall-clock time right after, then bootstrap a
  throwaway `Cluster` with `.spec.bootstrap.recovery` pointing at a
  completed backup and `recoveryTarget.targetTime` set to a moment shortly
  after that transaction. Confirm the recovered database contains the test
  row (proving WAL up to that point actually replayed, not just the
  nightly base backup) and delete the scratch cluster afterward. The exact
  `bootstrap.recovery`/`recoveryTarget` shape for the Barman Cloud plugin
  model is documented in
  [overlays/production/database/README-backup.md](overlays/production/database/README-backup.md)'s
  verification section and CNPG's own version-specific docs.
- **Health probes actually gate traffic**: temporarily scale Postgres to 0
  (or block its port) and confirm `/api/public/health` returns 503 and the
  pod is marked `NotReady` — not just logging an error while still silently
  receiving traffic.

## Rotating a production secret

```bash
# Regenerate, re-seal (same commands as initial bootstrap, fresh values),
# commit the new ciphertext:
git add overlays/production/webapp/sealed-secrets/gami-secrets.yaml
git commit -m "chore: rotate production secrets"
git push
```

The Sealed Secrets controller updates the underlying `Secret` on sync — but
**running pods don't pick up an env var change without a restart.** Bump a
pod-template annotation in the same commit (or run
`KUBECONFIG=<prod kubeconfig> kubectl rollout restart deployment/gami-webapp -n gami`
manually after confirming the sync applied) — otherwise the rotation
silently does nothing until the next unrelated rollout.

---

## Rolling back

Since deploys are just git commits, rolling back is `git revert` on the
commit that bumped the image tag, pushed the same way:

```bash
git log --oneline -- overlays/production/webapp/kustomization.yaml
git revert <bad-deploy-commit-sha>
git push
```

ArgoCD's `selfHeal: true` will apply the reverted state automatically.
Confirm the `gami-migrate` Job's behavior on rollback carefully — a schema
migration is not always safely reversible; check what the migration
actually did before assuming a straight revert is safe for the database
side, not just the application images.

---

## Troubleshooting

Cluster-level issues (clock skew causing cryptic auth failures, ArgoCD login
looping, Traefik entrypoint port collisions) are documented with exact
symptoms and fixes in [README-local.md](README-local.md)'s **Gotchas**
section — read that first, the causes are identical regardless of
environment.

Production-specific things to check first:
- Confirm which kubeconfig you're actually using — production's workloads
  (`kubectl get pods -n gami`) need production's own kubeconfig; ArgoCD
  operations (`kubectl get application ... -n argocd`) need **staging's**,
  since that's where ArgoCD itself runs. Mixing these up is the most common
  source of "it says NotFound" confusion now that these are two separate
  clusters.
- A stuck `gami-migrate` Job blocks the entire rollout by design
  (sync-wave `0` before `gami-webapp`'s wave `1`) — check
  `KUBECONFIG=<prod kubeconfig> kubectl logs job/gami-migrate -n gami`
  before assuming `gami-webapp` itself is broken.
- If `letsencrypt-production` fails to issue (rate-limited, DNS not
  pointing at the cluster yet, etc.), Traefik falls back to a self-signed
  default cert — a browser cert warning on the production hostname means
  check `KUBECONFIG=<prod kubeconfig> kubectl describe certificate -n gami`
  before assuming the app itself is broken.
- If a production Application shows `Unknown` health/sync status in
  staging's ArgoCD, first confirm the remote-cluster registration is still
  valid: `kubectl get secret -n argocd -l
  argocd.argoproj.io/secret-type=cluster` (against staging) should show a
  `prod` entry, and `argocd cluster list` (ArgoCD CLI, if installed) should
  show it as reachable — an expired or revoked token on the
  `argocd-manager` ServiceAccount would show up this way.
- Backup-specific issues (missing `ObjectStore`, credentials, plugin not
  installed) — see [overlays/production/database/README-backup.md](overlays/production/database/README-backup.md).
