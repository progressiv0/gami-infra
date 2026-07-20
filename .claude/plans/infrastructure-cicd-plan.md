# CI/CD & Infrastructure Automation Plan

> **Superseded in part — read before trusting details below.** This plan
> predates two real changes since it was written:
> 1. `gami-api` (the separate Go backend service) has been **removed
>    entirely** from `gami-app` — confirmed against its actual
>    `docker-compose.yml`, which only defines `gami-webapp` (+
>    postgres/mailpit/caddy/init/migrate). `gami-webapp` (Next.js) is the
>    whole app now; crypto operations run as a local binary/library inside
>    it, not over a JWT-secured network API. Every `gami-api`,
>    `GAMI_JWT_SECRET`, `GAMI_API_TOKEN`, `GAMI_KEY_ID`/`GAMI_PRIVATE_KEY`/
>    `GAMI_PUBLIC_KEY`, and `gami-signing-key` reference below is stale —
>    institution signing keys are per-institution application data in
>    Postgres now (`gami-app`'s `src/lib/institution-keys.ts`), not a
>    cluster Secret. The current, accurate manifests are in `base/` and
>    `overlays/`; this doc's Phase 3/3a sections describing `gami-api` and
>    its secrets are historical only.
> 2. **Node topology changed**: instead of one uniform 3-node HA cluster
>    running everything, each of the 3 nodes is now sized differently and
>    "home" to one environment (dev/staging/production), with per-environment
>    Postgres (only production has HA + S3 backup) and production's
>    `gami-webapp` spread across all 3 nodes via pod anti-affinity for real
>    redundancy. See the top-level `README.md`'s "Node topology" section for
>    the current design — the single shared `postgres-cluster.yaml` and
>    uniform-node-size assumptions described in Phase 4/5 below are
>    superseded by that.
>
> Kept as a historical record of the CI/CD pipeline design (GitHub Actions
> workflow shapes, general Sealed Secrets/ArgoCD reasoning) — still broadly
> accurate for those parts. Cross-check against `README.md` and the current
> `base/`/`overlays/` manifests for anything Postgres- or gami-api-shaped.

## Context

App repo: `authenticmemory/gami-app` (moved from `progressiv0/gami`; `main` is
stale — `dev` is the real source of truth and what this plan is based on).
Infra repo (`gami-infra`, this repo) stays at `progressiv0/gami-infra` for now,
moves to `authenticmemory` later.

**What's already true on `dev` today** (verified against the actual branch,
not assumed):
- PostgreSQL migration is **already done** — `docker-compose.yml`,
  `drizzle.config.ts`, and `src/lib/db/index.ts` already run a single Postgres
  instance (`postgres:18-alpine`). `better-sqlite3` is gone. There is no HA/
  replication yet — that's the real remaining work, not the migration itself.
- `.github/workflows/ci.yml` already runs on every push to `dev`/`main` and on
  PRs: Go `vet`/`test` for `gami-core`/`gami-api`, and `next build` for the
  webapp. It is more than "checks if the backend compiles."
- `.github/workflows/deploy.yml` already does a **manual** (`workflow_dispatch`
  only) SSH deploy to a single Hetzner VPS (`159.69.83.49`), gated by an
  explicit "no prod changes until I say" policy. It already uses GitHub
  Actions secrets (`DEPLOY_HOST`, `DEPLOY_USER`, `DEPLOY_SSH_KEY`).
- Both runtime images are **already distroless** (`gami-api`:
  `gcr.io/distroless/static-debian13`; `gami-webapp`: Next.js standalone
  output on `gcr.io/distroless/nodejs22-debian13`) — no shell, no package
  manager in either. Secrets that used to be parsed by a shell entrypoint are
  now read in-process (`gami-api`'s `config.LoadEnvFile`; `gami-webapp`'s
  `docker/start.js`), and DB migration/seed moved out of the webapp image
  into a one-shot `gami-migrate` Compose service (`target: builder`, which
  still has npm/drizzle-kit/tsx). This is the exact split k8s needs too — see
  `gami-migrate-job.yaml` in Phase 3.

  These images assume env vars are injected directly (k8s Secret / Compose
  `environment:` + a mounted file) — nothing in the image itself needs a
  `docker-entrypoint.sh` anymore. One Compose gotcha worth remembering:
  Compose's `env_file:` is resolved for *every* service before any container
  starts, so it can't be used to inject a file an init container writes at
  `up` time (it 404s on a fresh checkout, before `gami-init` ever runs) —
  that's why the secrets file is a regular volume mount read by the app
  itself, not `env_file:`.

**Goal for this plan:**
- Push to `main` / open a PR → build, test, security-scan, and run an
  AI-assisted PR review automatically. No deploy.
- Cutting a GitHub Release (manual trigger) → automatically builds images,
  updates `gami-infra`, and rolls out to production. No manual SSH step.
- Three VPS nodes in a single k3s cluster with an HA (embedded-etcd) control
  plane — losing any one node keeps the cluster and the app serving.
- PostgreSQL HA (CloudNativePG) with streaming replication across nodes, on
  cross-node replicated storage (Longhorn) rather than node-local disk.
- Secrets: GitHub Secrets are fine for CI-side credentials (image push,
  `gami-infra` push token, Claude API key) — that constraint was relaxed.
  What we still avoid is putting cluster-admin/kubeconfig credentials in
  GitHub: ArgoCD *pulls* from `gami-infra`, nothing ever pushes into the
  cluster from outside it.
- VPS provisioning is Terraform (Hetzner `hcloud` provider), not manually-run
  bash scripts. Node configuration (k3s join, OS-level day-2 ops like log
  cleanup) is Ansible. Non-technical users trigger day-2 ops from a page in
  the existing Next.js portal, not a CLI.

---

## Architecture

```
GitHub Actions (authenticmemory/gami-app)          ArgoCD (self-hosted
  - PR/push to main: test + security scan           on cluster)
    + Claude PR review                          ──► watches gami-infra
  - Release published: build images,                applies manifests
    push to ghcr.io, bump tag in gami-infra           rolling deploy
                │                                          │
                └──────────────────────────────────────────┘
                                   │
                k3s Cluster — HA control plane, 3 nodes, embedded etcd
     ┌──────────────────┬──────────────────┬──────────────────┐
     │ VPS Node 1        │ VPS Node 2        │ VPS Node 3        │
     │ (k3s server)      │ (k3s server)      │ (k3s server)      │
     │ gami-api pod      │ gami-api pod      │ gami-webapp pod   │
     │ postgres primary  │ postgres replica  │ postgres replica  │
     │ ArgoCD            │ Longhorn          │ Longhorn          │
     │ Longhorn          │ Traefik           │ Traefik           │
     │ Traefik           │ cert-manager      │                   │
     └──────────────────┴──────────────────┴──────────────────┘
```

**Ingress/TLS: k3s's bundled Traefik + cert-manager, not Caddy.** Caddy stays
local-dev-only (`docker-compose.yml`). k3s ships Traefik as its default
ingress controller — zero extra install — and it already runs HA-capable
across nodes. Getting Caddy to do the same job would mean building a custom
image (via `xcaddy`) with a distributed cert-storage plugin so every
per-node replica agrees on the same Let's Encrypt certificate; Traefik +
cert-manager is the standard, zero-custom-build path and needs nothing
Caddy-specific. See Phase 3's `ingress.yaml` / `cert-manager/` entries.

**On push to `main` / PR:**
1. GitHub Actions runs backend + webapp tests (existing `ci.yml`)
2. Security scans run: Trivy (deps + IaC), `gosec`, `npm audit` /
   dependency-review, optionally CodeQL
3. Claude reviews the PR automatically and leaves comments
4. Nothing is deployed

**On cutting a Release:**
1. Workflow builds `gami-api` and `gami-webapp` images, pushes to
   `ghcr.io/authenticmemory/*`
2. Updates the image tags in `gami-infra`'s `overlays/production/kustomization.yaml`
   (`kustomize edit set image`) via a scoped push token, commits, pushes
3. ArgoCD (running in-cluster, watching `gami-infra`) detects the diff and
   applies the Kustomize-rendered manifests
4. The `gami-migrate` Job runs as a PreSync hook and must complete before
   step 5 proceeds
5. k3s performs a rolling update — pods replaced one at a time, zero downtime,
   gated by each pod's readiness probe (`/healthz`, `/api/public/health`)
6. Pods are distributed across all 3 nodes — losing any one node doesn't take
   the app down

---

## Phase 1 — PostgreSQL (already done — nothing to migrate)

Verified on `dev`: `pg`/`drizzle-orm` are already the DB layer, Postgres
already runs as a `docker-compose` service, `DATABASE_URL` is already wired
through to the webapp. There is no SQLite left to remove and no schema
changes needed here.

The only remaining Postgres work is making the *existing* single instance
highly available — that's Phase 4, not this phase. This phase is kept in the
plan only as a record that it's done; no action items remain.

---

## Phase 2 — GitHub Actions: CI, Security Scanning, AI PR Review

Everything runs on GitHub-hosted runners — no self-hosted CI, no self-hosted
registry. This extends `authenticmemory/gami-app`'s existing
`.github/workflows/ci.yml` rather than replacing it.

**Add to `ci.yml`** (runs on every push to `main`/`dev` and every PR):

```yaml
  security-scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - name: Trivy filesystem scan
        uses: aquasecurity/trivy-action@master
        with:
          scan-type: fs
          exit-code: '1'
          severity: CRITICAL,HIGH
      - name: gosec (Go)
        run: |
          go install github.com/securego/gosec/v2/cmd/gosec@latest
          cd gami-backend && gosec ./...
      - name: npm audit (webapp)
        run: cd gami-webapp && npm audit --audit-level=high
      - name: Dependency review
        uses: actions/dependency-review-action@v4
        if: github.event_name == 'pull_request'

  claude-review:
    runs-on: ubuntu-latest
    if: github.event_name == 'pull_request'
    steps:
      - uses: actions/checkout@v6
      - uses: anthropics/claude-code-action@v1
        with:
          anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}
```

> CodeQL is worth adding too, but private repos need GitHub Advanced Security
> for code scanning — confirm the org's plan covers it before wiring it in.
> If not, `gosec` + Trivy + Semgrep's free tier cover most of the same OWASP
> ground for Go/JS.

**New `.github/workflows/release.yml`** (in `gami-app`):

```yaml
name: Release — build & deploy

on:
  release:
    types: [published]

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v7
      - uses: docker/login-action@v4
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/build-push-action@v7
        with:
          context: ./gami-backend
          push: true
          tags: ghcr.io/authenticmemory/gami-api:${{ github.event.release.tag_name }}
      - uses: docker/build-push-action@v7
        with:
          context: ./gami-webapp
          push: true
          tags: ghcr.io/authenticmemory/gami-webapp:${{ github.event.release.tag_name }}
      - name: Build + push gami-webapp builder stage (for the k8s gami-migrate Job)
        # target: builder — the distroless runner has no npm/drizzle-kit/tsx,
        # so the k8s migrate Job runs this tag instead, the same split
        # docker-compose.yml uses locally.
        uses: docker/build-push-action@v7
        with:
          context: ./gami-webapp
          target: builder
          push: true
          tags: ghcr.io/authenticmemory/gami-webapp:${{ github.event.release.tag_name }}-migrate

  update-infra-repo:
    needs: build-and-push
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with:
          repository: progressiv0/gami-infra
          token: ${{ secrets.INFRA_REPO_TOKEN }}
      - name: Install kustomize
        run: |
          curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
          sudo mv kustomize /usr/local/bin/
      - name: Bump image tags in overlays/production (Kustomize)
        run: |
          cd overlays/production   # release workflow always targets production;
                                    # staging is bumped manually / via a separate trigger
          kustomize edit set image \
            ghcr.io/authenticmemory/gami-api=ghcr.io/authenticmemory/gami-api:${{ github.event.release.tag_name }} \
            ghcr.io/authenticmemory/gami-webapp=ghcr.io/authenticmemory/gami-webapp:${{ github.event.release.tag_name }} \
            ghcr.io/authenticmemory/gami-webapp-migrate=ghcr.io/authenticmemory/gami-webapp:${{ github.event.release.tag_name }}-migrate
          git config user.name "gami-release-bot"
          git config user.email "release-bot@authenticmemory.org"
          git commit -am "chore: release ${{ github.event.release.tag_name }}"
          git push
```
This exactly matches `gami-app`'s actual `.github/workflows/release.yml` —
keep both in sync if either changes. `ghcr.io/authenticmemory/gami-webapp-migrate`
is a symbolic name that's never actually pushed under that exact string — it's
just the lookup key `base/gami-migrate-job.yaml` uses, which `kustomize edit
set image` rewrites to the real `gami-webapp:TAG-migrate` tag that *was* pushed.

`INFRA_REPO_TOKEN` is a fine-grained PAT scoped only to `gami-infra` with
`contents: write` — stored as a GitHub Actions secret in `gami-app`. This
replaces `deploy.yml`'s SSH-based deploy entirely; releasing is the new
manual gate ("push to main never deploys; cutting a release does").

---

## Phase 3 — `gami-infra` Repository

Kustomize, not Helm — the org runs exactly two environments (staging,
production), which is what overlays are for; a single `values.yaml` with
conditionals just re-invents overlays with worse tooling. Base manifests are
plain, boring Kustomize resources.

This has actually been scaffolded and rendered with `kubectl kustomize`
(not just written speculatively) — doing so caught three real bugs worth
recording so nobody re-discovers them the hard way:

1. **`configMapGenerator`'s default hash suffix breaks `envFrom` references.**
   `kubectl kustomize` renamed the generated ConfigMap to `gami-config-<hash>`
   but left every `envFrom: configMapRef: name: gami-config` in the
   Deployments/Job unrewritten — a 404 at apply time. Fixed with
   `generatorOptions: disableNameSuffixHash: true` in each overlay. Trade-off:
   pods don't auto-restart when `gami-config` changes — bump a pod-template
   annotation manually, same as the Secret-rotation caveat in Phase 3a.
2. **`ClusterIssuer` is cluster-scoped, but the `namespace:` transformer
   stamped a namespace onto it anyway** (verified: `kubectl kustomize` added
   `namespace: gami` to a `ClusterIssuer`, which isn't a namespaced kind at
   all). Worse, both overlays would then fight to own the *same* cluster-
   scoped resource name. Fixed by moving cert-manager out of `base/` entirely
   into a separate `cluster-wide/` Kustomization with no `namespace:` field,
   applied once via its own ArgoCD Application — shared by both environments,
   referenced by name only (`cert-manager.io/cluster-issuer: ...`).
3. **The HPA silently overrides `replicas:` overrides.** Staging sets
   `replicas: gami-api count: 1` for cost, but inherits base's
   `hpa.yaml` (`minReplicas: 2`) unchanged — the moment metrics-server reports
   anything, the HPA scales it back to 2. Fixed with a small `patches:` entry
   in `overlays/staging/kustomization.yaml` setting `minReplicas: 1,
   maxReplicas: 2` to match.

```
gami-infra/
  base/
    gami-api/
      deployment.yaml       ← ghcr.io/authenticmemory/gami-api, already
                                gcr.io/distroless/static-debian13:nonroot (uid 65532) —
                                securityContext.runAsNonRoot: true just asserts what's
                                already true, doesn't require an image change.
                                livenessProbe/readinessProbe: GET /healthz (unauthenticated,
                                see gami-api's middleware.JWT bypass)
      service.yaml            ← ClusterIP, internal-only (no Ingress — gami-webapp is the
                                only thing that ever calls gami-api, same as Compose's
                                "no host port")
      hpa.yaml                ← needs metrics-server in-cluster (not a k3s default);
                                without it, gami-api just sits at minReplicas
    gami-webapp/
      deployment.yaml       ← ghcr.io/authenticmemory/gami-webapp, already
                                gcr.io/distroless/nodejs22-debian13:nonroot (uid 65532),
                                ENTRYPOINT node docker/start.js.
                                livenessProbe/readinessProbe: GET /api/public/health
                                (pings Postgres — a healthy process with no DB access
                                can't serve real traffic, so this is a real readiness
                                signal, not a bare 200)
      service.yaml
      ingress.yaml          ← Traefik Ingress: two Host rules (app.authenticmemory.org,
                                verify.authenticmemory.org), both → gami-webapp Service —
                                the portal/verifier split is handled entirely by the app's
                                own src/middleware.ts host check, not at the ingress layer
    gami-migrate-job.yaml   ← k8s Job on the `gami-webapp-migrate` image (the `builder`
                                stage — has npm/drizzle-kit/tsx, pushed by release.yml's
                                second webapp build step) and `command: [npm, run, db:setup]` —
                                the exact same split Compose uses locally (see gami-app's
                                `gami-migrate` service), wired in as an ArgoCD PreSync hook so it
                                runs to completion before the Deployments roll. Also required a
                                real Dockerfile fix: gami-webapp's `builder` stage now switches
                                to the `node` user (uid 1000) *before* `WORKDIR`/`COPY`, verified
                                empirically — without it, `npm run db:setup` as a non-root uid
                                failed with EACCES on /app.
    postgres-cluster.yaml   ← CloudNativePG Cluster; auto-generates a `gami-postgres-app`
                                Secret (key `uri`) that gami-webapp/gami-migrate consume as
                                DATABASE_URL — verify the exact key name against your
                                installed CNPG version, this hasn't been tested against a
                                real cluster
    README-image-pull-secret.md   ← NOT a templated Secret — a real registry credential
                                shouldn't be committed even sealed; documents the one-time
                                `kubectl create secret docker-registry` command instead
    kustomization.yaml      ← namespace: gami (overridden to gami-staging by that overlay);
                                deliberately no configMapGenerator/SealedSecrets/cert-manager —
                                see bugs #1–#2 above
  cluster-wide/
    cert-manager/
      cluster-issuers.yaml  ← both letsencrypt-staging (LE's staging ACME server — untrusted
                                but functional test certs) and letsencrypt-production; not to
                                be confused with our own staging/production overlays
    kustomization.yaml      ← no namespace: field (see bug #2)
  overlays/
    staging/
      kustomization.yaml    ← namespace: gami-staging; image tags, replica counts (+ matching
                                HPA patch, bug #3), hostnames, letsencrypt-staging issuer
      sealed-secrets/       ← staging's own SealedSecrets (see Phase 3a) — independent
                                ciphertext from production, safe to commit
    production/
      kustomization.yaml    ← same, production values (production IS base's defaults, so
                                only staging carries an Ingress patch)
      sealed-secrets/       ← production's own SealedSecrets — never shared with staging
  argocd/
    app-gami-cluster-wide.yaml (path: cluster-wide — synced independently, before the others)
    app-gami-staging.yaml      (path: overlays/staging)
    app-gami-production.yaml   (path: overlays/production)
```

No Woodpecker, no self-hosted registry — both are gone from this design.
`gami-api`/`gami-webapp` pull from `ghcr.io/authenticmemory/*`, which needs an
`imagePullSecret` on the cluster (created once via an install script, see
`base/README-image-pull-secret.md` and Phase 5 — the credential lives only on
the cluster, not in `gami-infra` git).

**Secrets: Sealed Secrets, not Vault.** For a single-org closed environment
without a dedicated secrets platform, [Bitnami Sealed
Secrets](https://github.com/bitnami-labs/sealed-secrets) is the pragmatic
floor — real encryption at rest in git, no plaintext anywhere in the
pipeline, without standing up Vault/KMS infra this plan doesn't otherwise
need:
- Encrypt client-side with `kubeseal`, commit the resulting `SealedSecret` to
  the target overlay's own `sealed-secrets/` (not `base/` — staging and
  production must have independently-generated secrets, never a shared one
  scoped down per environment) — plaintext never touches the repo.
- A controller already running in-cluster holds the decryption key and turns
  it into a normal `Secret` at apply time.
- Plugs into Kustomize as just another resource in each overlay's
  `kustomization.yaml` — no ArgoCD Config Management Plugin needed (unlike
  SOPS+KSOPS, which needs a CMP wired into ArgoCD to decrypt at sync time).

**ArgoCD Applications** (`argocd/app-gami-{staging,production}.yaml`) — two
Applications instead of one Helm release, mapping directly onto "two
environments" rather than one values file with conditionals:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: gami-production
  namespace: argocd
spec:
  source:
    repoURL: https://github.com/progressiv0/gami-infra
    targetRevision: main
    path: overlays/production
  destination:
    server: https://kubernetes.default.svc
    namespace: gami
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

---

## Phase 3a — Secrets Bootstrap & Rotation

Sealed Secrets solves "how does an encrypted value get into git safely" —
it doesn't say who creates the plaintext in the first place. That's a human,
every time, for every one of these:

| Secret | Plaintext source | Notes |
|---|---|---|
| `GAMI_JWT_SECRET` | `openssl rand -hex 32` | Same command `gami-init` runs locally |
| `GAMI_API_TOKEN` | `gentoken -sub gami-webapp -scope "stamp upgrade verify" -days 365`, run **with `GAMI_JWT_SECRET` from the row above** | Must be minted with the same tool — it's a JWT signed by that secret, not an independent value |
| `NEXTAUTH_SECRET` | `openssl rand -hex 32` | |
| `GAMI_KEY_ID` / `GAMI_PRIVATE_KEY` | Real Ed25519 institutional signing key | **Never** auto-generated by any pipeline — provided by the institution out-of-band |
| `SMTP_PASS` | Email provider credential | Provided by a human |
| Postgres credentials | — | Not sealed at all — CloudNativePG generates and owns its own `Secret` (Phase 4); no manual step |

**Bootstrap runbook** (run once per environment — staging and production get
independently-generated secrets, never shared). Shown for production
(namespace `gami`); for staging, swap `--namespace gami` for `--namespace
gami-staging` and write into `overlays/staging/sealed-secrets/` instead —
staging and production run in separate namespaces on the same cluster, so
`kubeseal` output is only ever valid for the namespace it was sealed against
(SealedSecrets are scoped to namespace + name by default):

```bash
# 1. Generate the three app secrets (mirrors gami-init's local logic)
GAMI_JWT_SECRET=$(openssl rand -hex 32)
NEXTAUTH_SECRET=$(openssl rand -hex 32)
GAMI_API_TOKEN=$(GAMI_JWT_SECRET="$GAMI_JWT_SECRET" ./gentoken \
  -sub gami-webapp -scope "stamp upgrade verify" -days 365)

# 2. Fetch the cluster's public key (safe to do from anywhere — it's public;
#    kubeseal can't decrypt anything with it, only encrypt)
kubeseal --fetch-cert \
  --controller-namespace kube-system \
  --controller-name sealed-secrets > /tmp/sealed-secrets-cert.pem

# 3. Seal, straight into the overlay's SealedSecret file — never touches disk
#    as a plain Secret first
kubectl create secret generic gami-secrets \
  --namespace gami \
  --from-literal=GAMI_JWT_SECRET="$GAMI_JWT_SECRET" \
  --from-literal=GAMI_API_TOKEN="$GAMI_API_TOKEN" \
  --from-literal=NEXTAUTH_SECRET="$NEXTAUTH_SECRET" \
  --dry-run=client -o yaml \
  | kubeseal --cert /tmp/sealed-secrets-cert.pem -o yaml \
  > overlays/production/sealed-secrets/gami-secrets.yaml

# 4. GAMI_KEY_ID / GAMI_PRIVATE_KEY / SMTP_PASS: same shape, values supplied
#    by the institution / email provider instead of generated
kubectl create secret generic gami-signing-key \
  --namespace gami \
  --from-literal=GAMI_KEY_ID="did:web:authenticmemory.org#key-1" \
  --from-literal=GAMI_PRIVATE_KEY="<institution-provided hex key>" \
  --dry-run=client -o yaml \
  | kubeseal --cert /tmp/sealed-secrets-cert.pem -o yaml \
  > overlays/production/sealed-secrets/gami-signing-key.yaml

git add overlays/production/sealed-secrets/
git commit -m "chore: seal production secrets"
git push
```

`base/kustomization.yaml` never lists these directly — each overlay's
`kustomization.yaml` references its own `sealed-secrets/*.yaml`, so staging
and production genuinely have independent secrets, never a shared one
scoped down per-environment.

**Rotation**: re-run steps 1–4 with fresh values, commit the new ciphertext.
The Sealed Secrets controller updates the underlying `Secret` on sync, but
running pods don't pick up an env var change without a restart — bump a
pod-template annotation (e.g. `kubectl.kubernetes.io/restartedAt`) in the
same commit, or `kubectl rollout restart` manually after confirming the sync
applied.

**What CI never touches**: `INFRA_REPO_TOKEN` and `ANTHROPIC_API_KEY` (real
GitHub Actions secrets) only ever let CI push a commit that bumps an image
tag — `release.yml` has no path that reads or writes `sealed-secrets/`.
Plaintext app secrets exist in exactly two places: the operator's terminal
during this runbook, and inside the cluster after the controller decrypts
them. Never in git, never in CI logs.

---

## Phase 4 — PostgreSQL HA (CloudNativePG + Longhorn)

```yaml
# gami-infra/base/postgres-cluster.yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: gami-postgres
spec:
  instances: 3                  # one per node, matches the 3-node cluster
  affinity:
    topologyKey: kubernetes.io/hostname   # one instance per node, never doubled up
  storage:
    storageClass: longhorn
    size: 10Gi
  postgresql:
    pg_hba:
      - host gami gami 10.0.0.0/8 scram-sha-256
  backup:
    retentionPolicy: "7d"
```

Two layers of redundancy here, intentionally:
- **CloudNativePG** replicates at the Postgres level (streaming replication,
  ~30s automatic failover if the primary pod dies).
- **Longhorn** replicates the underlying volume across nodes, so a instance's
  data survives even total disk/node loss, not just process death — k3s's
  default `local-path` provisioner ties a PV to one node, which would break
  losing that node entirely.

`DATABASE_URL` is served via the CNPG-managed Service that always points at
the current primary — the webapp never needs to know which node that is.

---

## Phase 5 — VPS Provisioning (Terraform) + Node Config (Ansible)

No manually-run bash scripts. Terraform provisions the Hetzner infrastructure;
Ansible configures the OS and joins the k3s cluster; both are re-runnable and
version-controlled in `gami-infra`.

```
gami-infra/
  terraform/
    main.tf              ← hcloud_server x3, hcloud_network, hcloud_firewall, ssh key
    backend.tf            ← S3-compatible backend on Hetzner Object Storage
    variables.tf / outputs.tf   ← outputs the 3 node IPs for Ansible's inventory
  ansible/
    inventory/hcloud.yml  ← dynamic inventory sourced from Terraform/hcloud API
    playbooks/
      site.yml             ← k3s install + join (idempotent, safe to re-run)
      cleanup-logs.yml      ← journalctl vacuum, containerd image prune, Traefik/CNPG pod log rotation
      patch-os.yml          ← unattended-upgrades / apt/dnf patch + reboot-if-needed
    roles/
      k3s-server/
      node-baseline/        ← firewall, unattended-upgrades, non-root ops user
```

**Terraform** (`terraform/main.tf`, Hetzner `hcloud` provider):
```hcl
resource "hcloud_network" "gami" {
  name     = "gami-private"
  ip_range = "10.0.0.0/16"
}

resource "hcloud_server" "node" {
  count       = 3
  name        = "gami-node-${count.index + 1}"
  server_type = "cx32"
  image       = "ubuntu-24.04"
  location    = "fsn1"
  ssh_keys    = [hcloud_ssh_key.ops.id]
  network {
    network_id = hcloud_network.gami.id
  }
}

resource "hcloud_firewall" "gami" {
  name = "gami-firewall"
  rule { direction = "in" protocol = "tcp" port = "22"   source_ips = [var.admin_ip_cidr] }
  rule { direction = "in" protocol = "tcp" port = "6443" source_ips = [hcloud_network.gami.ip_range] }
}
```

State backend (`terraform/backend.tf`) points at Hetzner Object Storage
(S3-compatible), not a local file:
```hcl
terraform {
  backend "s3" {
    bucket                      = "gami-tfstate"
    key                         = "infra/terraform.tfstate"
    region                      = "eu-central"
    endpoints                   = { s3 = "https://fsn1.your-objectstorage.com" }
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
  }
}
```
The bucket access key/secret is passed via `AWS_ACCESS_KEY_ID`/
`AWS_SECRET_ACCESS_KEY` env vars at `terraform apply` time — never committed.
`terraform apply` runs from a GitHub Actions `workflow_dispatch` (same
click-to-run pattern as everything else in this plan) so infra changes are
still gated behind a manual trigger and leave an audit trail, without anyone
needing Terraform installed locally.

**Ansible** takes it from there: `playbooks/site.yml` runs against the 3 IPs
Terraform just created (via a dynamic `hcloud` inventory, so there's no IP
list to hand-maintain) and installs k3s with embedded etcd — node 1 with
`--cluster-init`, nodes 2/3 joining via `--server https://<node1-ip>:6443`.
All three run the k3s **server** role, so losing any single node still
leaves 2 of 3 etcd members up (a 2-node cluster can't do this — etcd needs an
odd member count to keep quorum after losing one). This replaces the old
per-node bash scripts entirely; re-running `site.yml` is safe and is how new
nodes get added or existing ones get reconciled.

**Registry note:** images come from `ghcr.io` (managed, valid TLS), so there's
no insecure-registry/containerd config needed — just an `imagePullSecret`
created once via a small Ansible task or `kubectl create secret`, applied
directly to the cluster and never committed to git.

> **Note on GPR file store:** GPR JSON files are NOT managed as a K8s
> persistent volume in production. They remain on local node storage written
> directly by the webapp pod. Replication across nodes is out of scope for
> this automation.

All nodes communicate over the `hcloud_network` private network (not public
internet); only port 22 (from an admin CIDR) and the k3s API port are exposed
externally per the firewall above.

---

## Phase 6 — Self-Serve Ops (backup, restore, log cleanup) from the portal

Goal: someone without kubectl/SSH/Ansible knowledge can do routine ops from a
page in the existing Next.js portal (`gami-webapp`). Split by where the task
actually lives — database ops stay in Kubernetes, host ops stay in Ansible —
rather than forcing everything through one tool:

**Database backup** (`/admin/ops` page, new `platform-admin`-only role,
separate from the existing institution/admin roles):
- Backend calls the in-cluster Kubernetes API (via a `ServiceAccount` bound
  to a `Role` scoped to *only* `create`/`get` on
  `backups.postgresql.cnpg.io` in the `gami` namespace — nothing broader)
  to create an on-demand CNPG `Backup` object.
- Polls until CNPG reports it complete; CNPG has already pushed it to the
  Hetzner Object Storage bucket (same barman-cloud target configured in
  Phase 4's `backup:` block).
- Backend generates a presigned S3-style URL for that object and the page
  offers it as a download. No SSH, no Ansible, no kubeconfig ever touches
  the webapp — just the narrowly-scoped in-cluster service account token
  it already gets for free as a pod.

**Database restore**: reachable from the same page but deliberately not a
single click — CNPG's restore model is "bootstrap a new `Cluster` from a
backup/PITR target," which is inherently a bigger, order-sensitive operation.
Gate it behind a typed confirmation (e.g. type the environment name) and
restrict it to `platform-admin`, regardless of how nice the button looks.

**Log cleanup / OS-level maintenance** (host disk, not Kubernetes): the page
calls the GitHub API (`POST .../actions/workflows/ops.yml/dispatches`) on
`gami-infra`, using a fine-grained PAT (scoped to `actions: write` on just
that repo) held server-side in the webapp's environment. That dispatches
`ansible/playbooks/cleanup-logs.yml` on a GitHub Actions runner over SSH —
the SSH private key lives only in that GitHub Actions secret, never in the
webapp's container or image. This mirrors the existing manual-deploy pattern
the team already trusts, just triggered by a button instead of the Actions
tab.

---

## Verification

1. **PostgreSQL**: already verified working on `dev` (`docker compose up`,
   drizzle-kit push, login). Nothing to re-verify for Phase 1.
2. **CI on push/PR**: push a branch or open a PR — confirm tests, security
   scans, and the Claude review comment all run.
3. **Release deploy**: publish a GitHub Release — confirm the workflow builds
   images, updates `overlays/production` in `gami-infra`, and ArgoCD rolls out
   the change. Confirm a plain push to `main` does *not* deploy.
3a. **Migrate-before-rollout**: confirm the `gami-migrate` Job (ArgoCD PreSync
    hook) runs to completion — and the Deployments don't roll — before the DB
    schema is up to date; re-running a sync with no schema change is a no-op.
3b. **Sealed Secrets**: confirm a `SealedSecret` committed to an overlay's
    `sealed-secrets/` is unreadable without the in-cluster controller's key
    (`kubectl get secret -o yaml` on the *sealed* resource shows only
    ciphertext), and that ArgoCD still syncs it into a plain `Secret` the
    Deployments can mount.
3c. **Health probes actually gate traffic**: kill the DB connection from a
    running `gami-webapp` pod (e.g. scale Postgres to 0 briefly) — confirm
    `/api/public/health` starts returning 503 and the pod is marked
    NotReady, not just logging an error while still receiving traffic.
3d. **Ingress/TLS**: hit both `https://app.<domain>` and
    `https://verify.<domain>` from outside the cluster — confirm cert-manager
    issued a real, browser-trusted Let's Encrypt cert for each (not Traefik's
    default self-signed fallback), and that both route to the same
    `gami-webapp` Service with the correct host-based behavior (portal vs.
    verifier), matching what `docker-compose.local.yml` already proves for
    `localhost`/`verify.localhost`.
4. **Control-plane HA**: stop k3s on any one of the 3 nodes
   (`systemctl stop k3s`) — confirm the other two keep serving traffic and
   the API server stays reachable within ~60s.
5. **PostgreSQL failover**: delete the primary postgres pod — confirm
   CloudNativePG promotes a replica and the webapp reconnects automatically.
6. **Storage resilience**: cordon/drain the node hosting a Postgres replica's
   Longhorn volume — confirm Longhorn keeps the data available from its other
   replicas.
7. **Security scan gate**: introduce a known-vulnerable dependency — confirm
   Trivy/`npm audit`/`gosec` blocks the PR.
8. **Terraform**: `terraform plan` on a clean checkout shows no drift against
   the running Hetzner infra; `terraform apply` via the `workflow_dispatch`
   workflow succeeds end-to-end against the S3-compatible state backend.
9. **Ansible**: re-running `site.yml` against all 3 nodes is a no-op (proves
   idempotency); `cleanup-logs.yml` run once by hand, then again via the
   `/admin/ops` button, to confirm both paths work identically.
10. **Ops page**: as `platform-admin`, trigger a backup and confirm a working
    download link appears; confirm a non-`platform-admin` user cannot see or
    trigger any of `/admin/ops`.

---

## Rollout Order
1. Security + Claude review jobs added to `ci.yml` (low risk, no infra needed)
2. `release.yml` workflow added to `gami-app`, `INFRA_REPO_TOKEN` +
   `ANTHROPIC_API_KEY` secrets set
3. `gami-infra` repo scaffolded: Kustomize `base/` + `overlays/{staging,production}`,
   two ArgoCD Applications, Terraform (`terraform/`), Ansible (`ansible/`)
4. Hetzner Object Storage bucket created for Terraform state; `terraform
   apply` (via `workflow_dispatch`) provisions the 3-node network + firewall
   + servers
5. `ansible-playbook site.yml` installs k3s with embedded etcd across all 3
   nodes (HA control plane)
6. Longhorn + ArgoCD + CloudNativePG + cert-manager + the Sealed Secrets
   controller installed on the cluster (Traefik is already there — it ships
   with k3s); `imagePullSecret` for `ghcr.io` created
7. Secrets bootstrap runbook (Phase 3a) run once per environment; first real
   `SealedSecret`s committed to `overlays/{staging,production}/sealed-secrets/`
8. First GitOps deploy via a test Release
9. HA validation (control plane, Postgres failover, storage resilience)
10. `platform-admin` role + `/admin/ops` page added to `gami-webapp`: backup
    download wired to the CNPG/Kubernetes API, log cleanup wired to the
    `ops.yml` GitHub Actions dispatch
11. Cut over production traffic from the current single Hetzner VPS to the
    cluster; retire `deploy.yml` and the old VPS once confirmed stable
