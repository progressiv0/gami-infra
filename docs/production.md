# Production

Production runs on its own single-node k3s cluster (`gami-prod`) — a fully
separate cluster from staging, not a namespace on a shared one. Namespace
`gami`, hostnames `app.authenticmemory.org` and
`verify.authenticmemory.org`.

**There is no ArgoCD on production's node.** ArgoCD lives on staging and
manages production as a registered remote cluster. Practically:

- ArgoCD operations (`kubectl get application -n argocd`) run against
  **staging**, even for production Applications.
- Production workloads (`kubectl get pods -n gami`) run against
  **production's** kubeconfig.

Mixing those up is the most common source of "it says NotFound" confusion.

Production is split into two Applications: `overlays/production/database/`
(CNPG + S3 backup) and `overlays/production/webapp/` (the app), so the
database could come up ahead of the app.

---

## Deploying a release

Production is **gated by a button**. Pushing to `gami-app`'s `main` only
builds and publishes `ghcr.io/authenticmemory/gami-webapp:main-<short-sha>`
— it never deploys.

1. `gami-app` → **Actions** → **Deploy to production** → *Run workflow*.
2. Leave **tag** empty for the current HEAD, or give an explicit tag
   (`main-a1b2c3d`) to deploy — or roll back to — an earlier build.
3. The workflow verifies the image exists in the registry, then commits the
   tag into `overlays/production/webapp/` here.
4. ArgoCD syncs it onto the `prod` cluster.

The registry check matters: without it a typo'd tag would only surface as
`ImagePullBackOff` *after* ArgoCD had already rolled the Deployment forward.

**Don't hand-edit the `images:` tag** — the workflow owns it.

**Rolling back** is the same button with an older tag. Tags are never
reused, so previously deployed images stay addressable indefinitely.

On sync, `gami-migrate` (wave 0) completes before `gami-webapp` (wave 1)
rolls out. Migrations therefore re-run on every promotion, before new pods
serve — see [database.md](database.md) for what that means for your data.

A single replica on a single node means a brief gap while the old pod
terminates and the new one passes readiness. Not zero-downtime, by design —
there's no second node.

```bash
curl -s https://app.authenticmemory.org/api/version
```

---

## Verifying a deploy

```bash
KUBECONFIG=<prod kubeconfig> kubectl get pods -n gami -o wide
kubectl get application gami-production-webapp -n argocd    # against staging
```

```bash
curl -I https://app.authenticmemory.org
curl -I https://verify.authenticmemory.org
```

Confirm a real certificate, not the ACME staging CA:

```bash
openssl s_client -connect app.authenticmemory.org:443 \
  -servername app.authenticmemory.org </dev/null 2>/dev/null | \
  openssl x509 -noout -issuer
```

Watch a rollout, and poll `/api/version` from another terminal to see
exactly when the new build takes over (it reports the baked-in `BUILD_SHA`):

```bash
KUBECONFIG=<prod kubeconfig> kubectl rollout status deployment/gami-webapp -n gami
```

Note `/api/version` is a static 200 that deliberately does **not** touch
Postgres — a database outage will not mark the pod `NotReady`. Requests that
need the DB fail individually instead. That's the intended tradeoff; don't
test for a 503 here.

---

## Secrets

Production seals `gami-secrets` and `gami-smtp` into git, against
production's **own** Sealed Secrets controller. Never reuse staging's values
— and note a SealedSecret sealed against staging's keypair is permanently
undecryptable here.

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

kubectl create secret generic gami-smtp \
  --namespace gami \
  --from-literal=SMTP_USER="<real SMTP username>" \
  --from-literal=SMTP_PASS="<real SMTP password>" \
  --dry-run=client -o yaml \
  | kubeseal --cert /tmp/sealed-secrets-cert-prod.pem -o yaml \
  > overlays/production/webapp/sealed-secrets/gami-smtp.yaml
```

The controller lands in `kube-system` (the upstream manifest hardcodes it),
which is why `--controller-namespace kube-system --controller-name
sealed-secrets-controller` is needed — the shorter `sealed-secrets` some
docs assume won't match.

Add the filenames to
`overlays/production/webapp/sealed-secrets/kustomization.yaml` (it starts as
`resources: []`), then commit and push.

Also replace the SMTP **placeholders** in
`overlays/production/webapp/kustomization.yaml`'s `configMapGenerator`
(`SMTP_HOST=smtp.example.com` etc.) with real values before the first deploy.

No `gami-signing-key` — institution signing keys are application data in
Postgres, created through the app's admin UI.

### Rotating

Regenerate, re-seal, commit. The controller updates the underlying `Secret`
on sync — but **running pods don't pick up an env var change without a
restart**. Bump a pod-template annotation in the same commit, or restart
afterwards. Use `delete pod`, not `rollout restart`, which ArgoCD sees as
drift and corrects with a full sync (re-running the migrate Job):

```bash
KUBECONFIG=<prod kubeconfig> kubectl delete pod -l app=gami-webapp -n gami
```

---

## Backups

Production is the only environment that backs up. Nightly base backup to S3
plus continuous WAL archiving (`archive_timeout: 60s`) for point-in-time
recovery, bounding data loss to about a minute.

Full detail — setup, on-demand backups, changing parameters, PITR drills —
in [database.md](database.md).

The one thing to do at least once, before you need it: run an actual restore
drill in a maintenance window. A green `ScheduledBackup` object proves
nothing on its own.

---

## Rolling back

Deploys are git commits, so:

```bash
git log --oneline -- overlays/production/webapp/kustomization.yaml
git revert <bad-deploy-commit-sha>
git push
```

ArgoCD's `selfHeal` applies the reverted state. **Check the migration
carefully** — a schema change is not always safely reversible, and reverting
the image doesn't revert the database.

---

## Production-specific things to check first

- Which kubeconfig you're using (see the top of this page).
- A stuck `gami-migrate` Job blocks the whole rollout by design — check
  `kubectl logs job/gami-migrate -n gami` before assuming the app is broken.
- If `letsencrypt-production` fails to issue, Traefik falls back to a
  self-signed cert; a browser warning on the production hostname means
  checking `kubectl describe certificate -n gami` first.
- If a production Application shows `Unknown` in staging's ArgoCD, confirm
  the remote registration is still valid:
  `kubectl get secret -n argocd -l argocd.argoproj.io/secret-type=cluster`
  should show a `prod` entry. An expired `argocd-manager` token shows up
  this way.

Everything else: [troubleshooting.md](troubleshooting.md).

---

## Related

- [Database](database.md) — backups, restores, PITR
- [Staging](staging.md) — the staging equivalent
- [Server setup](setup-server.md) — bootstrapping from scratch
