# Production deployment guide

Deploys production onto the shared 3-node Hetzner k3s cluster (same cluster
as dev/staging, separate namespace: `gami`). Read [README.md](README.md)
first for what each piece is — especially its **"Node topology"** section:
production is the environment that gets real redundancy, with `gami-webapp`
spread across all 3 nodes (not just the dedicated big one) and the only
Postgres cluster with HA + S3 backup.

Read [README-staging.md](README-staging.md) too if you haven't bootstrapped
the cluster yet — **cluster bootstrap (Terraform + Ansible + operator
installs) is done once for the whole cluster, not once per environment.** If
another environment is already running on this cluster, skip straight to
[Deploying a production release](#deploying-a-production-release).

> **Status check**: `terraform/` has not been run through `terraform
> plan`/`apply` against real infrastructure yet (see `terraform/README.md`
> and [README-staging.md](README-staging.md)'s callout). If you're standing
> up the cluster for the first time, do that validation via staging first —
> don't let production be the first real test of unreviewed Terraform.

---

## Prerequisites (if the cluster doesn't exist yet)

Identical to staging's prerequisites — this is one cluster, not separate
ones per environment. Follow [README-staging.md](README-staging.md)'s
**One-time cluster bootstrap** section in full (Terraform provisioning,
Ansible k3s+ArgoCD bootstrap — cert-manager, CloudNativePG, and
the Sealed Secrets controller all install themselves automatically via
ArgoCD once that's done, see [README.md](README.md)'s `cluster-operators/`
section). Come back here once that's done.

Also confirm the **Barman Cloud plugin** specifically came up — it's the
one piece of `cluster-operators/` that only production needs:
```bash
kubectl get pods -n cnpg-system -l app.kubernetes.io/name=barman-cloud
```
See [overlays/production/README-backup.md](overlays/production/README-backup.md)
for what depends on it.

The only production-specific one-time steps are below.

### Image pull secret (production namespace)

Same command as staging, different namespace:

```bash
kubectl create secret docker-registry ghcr-pull-secret \
  --namespace gami \
  --docker-server=ghcr.io \
  --docker-username=<github-username> \
  --docker-password=<fine-grained PAT, read:packages only> \
  --docker-email=<email>
```

### Seal production's secrets

**Never reuse dev's or staging's secrets here.** Production gets its own,
independently-generated values. There's no separate backend service anymore
(`gami-app` dropped it — see [README.md](README.md)), so the app secret
surface is small: just `NEXTAUTH_SECRET` and SMTP credentials.

```bash
NEXTAUTH_SECRET=$(openssl rand -hex 32)

kubeseal --fetch-cert \
  --controller-namespace kube-system \
  --controller-name sealed-secrets-controller > /tmp/sealed-secrets-cert.pem

kubectl create secret generic gami-secrets \
  --namespace gami \
  --from-literal=NEXTAUTH_SECRET="$NEXTAUTH_SECRET" \
  --dry-run=client -o yaml \
  | kubeseal --cert /tmp/sealed-secrets-cert.pem -o yaml \
  > overlays/production/sealed-secrets/gami-secrets.yaml

# Real SMTP credential from your email provider
kubectl create secret generic gami-smtp \
  --namespace gami \
  --from-literal=SMTP_USER="<real SMTP username>" \
  --from-literal=SMTP_PASS="<real SMTP password>" \
  --dry-run=client -o yaml \
  | kubeseal --cert /tmp/sealed-secrets-cert.pem -o yaml \
  > overlays/production/sealed-secrets/gami-smtp.yaml
```

No `gami-signing-key` secret — institution signing keys are per-institution
application data managed in Postgres (`gami-app`'s
`src/lib/institution-keys.ts`), created through the app's own admin UI/API,
not sealed at the infra level.

Add the filenames to `overlays/production/sealed-secrets/kustomization.yaml`
(starts as `resources: []`):

```yaml
resources:
  - gami-secrets.yaml
  - gami-smtp.yaml
```

```bash
git add overlays/production/sealed-secrets/
git commit -m "chore: seal production secrets"
git push
```

**Before the first real deploy**, also replace the SMTP placeholder values
baked into `overlays/production/kustomization.yaml`'s `configMapGenerator`
(`SMTP_HOST=smtp.example.com` etc. are literally placeholders in the
committed file) with real values.

### Set up production Postgres backups

Production is the **only** environment that backs up to S3 (dev/staging
deliberately don't — see [README.md](README.md)'s "Node topology" section).
Full setup steps, the on-demand backup command, and how to verify a restore
actually works are in
[overlays/production/README-backup.md](overlays/production/README-backup.md)
— do this before your first real production sync, not after.

### Apply the production Application

```bash
kubectl apply -f argocd/app-gami-production.yaml
kubectl get application gami-production -n argocd -w
```

Watch for the CNPG `Cluster` (`overlays/production/postgres-cluster.yaml`)
to provision all 3 Postgres instances, and the `ObjectStore`/
`ScheduledBackup` to come up healthy:
```bash
kubectl get cluster gami-postgres -n gami
kubectl get objectstore -n gami
kubectl get scheduledbackup -n gami
```

---

## Deploying a production release

Unlike staging/dev, production deploys are meant to go through a **gated,
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
   `overlays/production/`, commits, and pushes.
4. ArgoCD (already watching `overlays/production` via
   `argocd/app-gami-production.yaml`) detects the diff and syncs.
5. The `gami-migrate` PreSync hook runs to completion before `gami-webapp`
   rolls out.
6. k3s performs a rolling update, one pod at a time, gated by the readiness
   probe. `gami-webapp` runs 3 replicas spread across all 3 nodes via
   podAntiAffinity (not just the dedicated big node) — losing any one node
   doesn't take production down.

**If `release.yml` doesn't exist yet in `gami-app`**, or you need to deploy
manually as a one-off before that automation is wired up, do the equivalent
by hand:

```bash
cd gami-infra/overlays/production
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
kubectl get pods -n gami -o wide
kubectl get application gami-production -n argocd
```

Confirm all 3 `gami-webapp` pods landed on different nodes (that's the whole
point of the podAntiAffinity patch):
```bash
kubectl get pods -n gami -o wide -l app=gami-webapp
```
Each pod's `NODE` column should be distinct — dev, staging, and prod nodes,
one `gami-webapp` pod each.

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
kubectl get pods -n gami -o wide
```
`gami-migrate` should show `Completed`, timestamped before the current
`gami-webapp` pods.

**Rolling update sanity check**: watch a deploy in progress —
```bash
kubectl rollout status deployment/gami-webapp -n gami
```
Confirm zero downtime by hitting the health endpoint in a loop from another
terminal while the rollout runs:
```bash
while true; do curl -s -o /dev/null -w "%{http_code}\n" https://app.authenticmemory.org/api/public/health; sleep 1; done
```

---

## HA verification (worth doing at least once, not just after every deploy)

These prove the actual point of the node topology design — do them in a
maintenance window, not casually against live traffic:

- **Control-plane HA**: stop k3s on one node
  (`systemctl stop k3s` or the equivalent OpenRC command) — confirm the
  other two nodes keep serving and the API server stays reachable within
  ~60s. Bring it back with `systemctl start k3s`.
- **`gami-webapp` survives losing the dedicated prod node specifically**:
  cordon/drain `gami-node-prod` — confirm the other 2 `gami-webapp` replicas
  (already running on the dev/staging nodes, via podAntiAffinity) keep
  serving `app.authenticmemory.org` without interruption, and a 3rd replica
  eventually reschedules once the node is uncordoned.
- **Postgres failover**: delete the primary Postgres pod — confirm
  CloudNativePG promotes a replica automatically and `gami-webapp` reconnects
  without manual intervention.
- **Storage resilience**: this is what the Postgres failover test above
  already covers — each CNPG instance has its own independent `local-path`
  PV, so node-loss tolerance comes from CNPG's own streaming replication,
  not a replicated storage layer underneath.
- **Health probes actually gate traffic**: temporarily scale Postgres to 0
  (or block its port) and confirm `/api/public/health` returns 503 and the
  pod is marked `NotReady` — not just logging an error while still silently
  receiving traffic.
- **Backup/restore actually works** — see
  [overlays/production/README-backup.md](overlays/production/README-backup.md)'s
  verification section; a green `ScheduledBackup` status alone doesn't prove
  a restore will work.

## Rotating a production secret

```bash
# Regenerate, re-seal (same commands as initial bootstrap, fresh values),
# commit the new ciphertext:
git add overlays/production/sealed-secrets/gami-secrets.yaml
git commit -m "chore: rotate production secrets"
git push
```

The Sealed Secrets controller updates the underlying `Secret` on sync — but
**running pods don't pick up an env var change without a restart.** Bump a
pod-template annotation in the same commit (or run `kubectl rollout restart
deployment/gami-webapp -n gami` manually after confirming the sync applied)
— otherwise the rotation silently does nothing until the next unrelated
rollout.

---

## Rolling back

Since deploys are just git commits, rolling back is `git revert` on the
commit that bumped the image tag, pushed the same way:

```bash
git log --oneline -- overlays/production/kustomization.yaml
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
- Confirm you're actually looking at the `gami` namespace, not
  `gami-staging`/`gami-dev` — easy to mix up since all three run on the same
  cluster.
- A stuck `gami-migrate` Job blocks the entire rollout by design (PreSync
  hook) — check `kubectl logs job/gami-migrate -n gami` before assuming
  `gami-webapp` itself is broken.
- If `letsencrypt-production` fails to issue (rate-limited, DNS not
  pointing at the cluster yet, etc.), Traefik falls back to a self-signed
  default cert — a browser cert warning on the production hostname means
  check `kubectl describe certificate -n gami` before assuming the app
  itself is broken.
- If all 3 `gami-webapp` replicas landed on the same node (podAntiAffinity
  is a *soft* preference, not a hard requirement) — check
  `kubectl describe pod <pod> -n gami` for scheduling events; this can
  happen if the other 2 nodes are genuinely too resource-constrained to fit
  a replica, which is worth knowing about even though it's not a hard
  failure.
- Backup-specific issues (missing `ObjectStore`, credentials, plugin not
  installed) — see [overlays/production/README-backup.md](overlays/production/README-backup.md).
