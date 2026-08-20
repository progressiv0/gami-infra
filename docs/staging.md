# Staging

Staging runs on its own single-node k3s cluster (`gami-staging`), which is
also where the one central ArgoCD instance lives — so this node manages
production too.

Namespace `gami-staging`, hostnames `staging.authenticmemory.org` and
`verify-staging.authenticmemory.org`.

If the infrastructure doesn't exist yet, start at
[setup-server.md](setup-server.md).

---

## Deploying an app change

Fully automatic: **push to `gami-app`'s `staging` branch and nothing else is
needed.**

1. `gami-app`'s `release.yml` builds and pushes
   `ghcr.io/authenticmemory/gami-webapp:staging-<short-sha>` — a unique tag,
   never reused.
2. The same workflow's `bump-staging` job checks out *this* repo, runs
   `kustomize edit set image` in `overlays/staging/`, and commits.
3. ArgoCD sees the changed tag and syncs.

That commit is what makes the deploy visible — ArgoCD syncs on a manifest
diff, so the tag has to actually change. **Don't hand-edit the `images:` tag**
in `overlays/staging/kustomization.yaml`; CI owns it and will overwrite you.

**Non-image changes** (config, hostnames) — edit the overlay directly,
commit, push.

### What happens on sync

| Wave | Resource |
|---|---|
| -1 | `gami-config` ConfigMap, Postgres Deployment + PVC + Service |
| 0 | `gami-migrate` Job — must complete before anything proceeds |
| 1 | `gami-webapp` Deployment, and the GPR store PVC it mounts |

The migrate Job re-runs on **every** sync — it carries
`Replace=true,Force=true` because Jobs are immutable. That means
`drizzle-kit push` runs every time; see [database.md](database.md) for why
that matters if you've restored a dump.

Confirm what landed:

```bash
curl -s https://staging.authenticmemory.org/api/version
```

`sha` is the commit the running image was built from.

---

## Verifying

```bash
sudo k3s kubectl get pods -n gami-staging
sudo k3s kubectl get application gami-staging -n argocd
```

```bash
curl -I https://staging.authenticmemory.org
curl -I https://verify-staging.authenticmemory.org
```

Staging uses `letsencrypt-production`, so these should present a real,
browser-trusted certificate. Remember Let's Encrypt rate limits are **per
registered domain** — staging shares `authenticmemory.org`'s budget with
production (50 certs/week, 5 identical re-issues/week). If you're thrashing
certificates, switch back to `letsencrypt-staging` while iterating.

Confirm migrate-before-rollout held — `gami-migrate` should show `Completed`
with an earlier timestamp than the current `gami-webapp` pod:

```bash
sudo k3s kubectl get pods -n gami-staging -o wide
```

### Checking captured email

Mailpit catches all outbound mail (magic-link sign-ins, notices). It's
deliberately ClusterIP-only — it holds live single-use sign-in tokens, so a
standing exposed port would be an auth bypass. Reach it over an SSH tunnel:

```bash
ssh -i ~/.ssh/ops@authenticmemory.org -L 8025:127.0.0.1:8025 ops@$GAMI_STAGING_IP \
  'sudo k3s kubectl -n gami-staging port-forward svc/mailpit 8025:8025'
```

Then open <http://localhost:8025>. Inside the cluster it's `mailpit:1025`,
which is what `SMTP_HOST` points at.

---

## Secrets — nothing to do

Staging's Secrets are generated **on the cluster** by `site.yml`'s
`app_secrets` role. There's no `kubeseal` step and no credential in git.

| Secret | Keys | Used by |
|---|---|---|
| `gami-postgres-app` | `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`, `uri` | Postgres initialises from `POSTGRES_*` via `envFrom`; the app connects with `uri` |
| `gami-secrets` | `NEXTAUTH_SECRET` | `gami-webapp` |

The password is written into `POSTGRES_PASSWORD` and into `uri` from one
shell variable on the node, so they can't drift, and the plaintext never
reaches the Ansible controller or git.

Both are **generate-once** — the role skips them if they exist, so re-running
`site.yml` never rotates them. That's deliberate: `POSTGRES_PASSWORD` is only
read by `initdb` on the database's first start, and rotating
`NEXTAUTH_SECRET` invalidates every live session and outstanding magic link.

To rotate on purpose, delete the Secret and re-run — **and for the database,
wipe the PVC too**, since an existing data directory keeps the old password.
Staging has no backup, so that destroys the data. See
[database.md](database.md) for the non-destructive alternative.

ArgoCD never prunes these — it only prunes resources it created itself,
which is also why `ghcr-pull-secret` is safe to create out of band.

Institution signing keys are **not** cluster secrets — they're
per-institution application data in Postgres, managed through the app's own
admin UI.

---

## Staging-specific things to check first

- `kubectl -n gami-staging get secret gami-postgres-app gami-secrets`
  returns both — if either is missing, re-run `site.yml --tags app-secrets`.
- `ghcr-pull-secret` exists in `gami-staging` specifically — it's
  namespace-scoped, so one created in `gami` doesn't help.
- The image tag in `overlays/staging/kustomization.yaml` actually exists in
  GHCR — a typo shows up only as `ImagePullBackOff`.
- Staging's Postgres has **no backup at all**. That's intentional. Don't
  expect it to survive anything worse than a pod restart.
- Production's Applications appear in staging's ArgoCD too (it manages
  both). If they're `Unknown`, check the remote registration:
  `kubectl get secret -n argocd -l argocd.argoproj.io/secret-type=cluster`
  should show a `prod` entry.

Everything else: [troubleshooting.md](troubleshooting.md).

---

## Related

- [Database](database.md) — dumps, restores, why migrations can eat data
- [Production](production.md) — the production equivalent of this page
- [Architecture](architecture.md) — how staging and production differ
