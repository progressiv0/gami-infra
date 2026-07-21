# Dev deployment guide

Deploys the shared dev environment onto the real 3-node Hetzner k3s cluster
— the same cluster staging and production run on, in its own namespace
(`gami-dev`). Read [README.md](README.md) first, especially its **"Node
topology"** section: dev is "home" to the small `gami-node-dev` box (which
also hosts ArgoCD itself), but that's a scheduling preference, not a
separate cluster.

If the cluster doesn't exist yet, follow
[README-staging.md](README-staging.md)'s **One-time cluster bootstrap**
section in full first (Terraform provisioning, Ansible k3s+ArgoCD bootstrap,
cluster-wide operators) — that's done once for the whole cluster, not once
per environment. Come back here once that's done.

---

## One-time setup specific to dev

### Image pull secret

```bash
kubectl create secret docker-registry ghcr-pull-secret \
  --namespace gami-dev \
  --docker-server=ghcr.io \
  --docker-username=<github-username> \
  --docker-password=<fine-grained PAT, read:packages only> \
  --docker-email=<email>
```

### Seal dev's secrets

Dev needs its **own**, independently-generated secrets — never copy
staging's or production's:

```bash
NEXTAUTH_SECRET=$(openssl rand -hex 32)

kubeseal --fetch-cert \
  --controller-namespace kube-system \
  --controller-name sealed-secrets-controller > /tmp/sealed-secrets-cert.pem

kubectl create secret generic gami-secrets \
  --namespace gami-dev \
  --from-literal=NEXTAUTH_SECRET="$NEXTAUTH_SECRET" \
  --dry-run=client -o yaml \
  | kubeseal --cert /tmp/sealed-secrets-cert.pem -o yaml \
  > overlays/dev/sealed-secrets/gami-secrets.yaml

kubectl create secret generic gami-smtp \
  --namespace gami-dev \
  --from-literal=SMTP_USER="<real SMTP username, or Mailpit/dev SMTP>" \
  --from-literal=SMTP_PASS="<real SMTP password>" \
  --dry-run=client -o yaml \
  | kubeseal --cert /tmp/sealed-secrets-cert.pem -o yaml \
  > overlays/dev/sealed-secrets/gami-smtp.yaml
```

No institution signing key secret — those are per-institution application
data in Postgres now (`gami-app`'s `src/lib/institution-keys.ts`), not a
cluster Secret.

```yaml
# overlays/dev/sealed-secrets/kustomization.yaml
resources:
  - gami-secrets.yaml
  - gami-smtp.yaml
```

```bash
git add overlays/dev/sealed-secrets/
git commit -m "chore: seal dev secrets"
git push
```

### Apply the ArgoCD Application

```bash
kubectl apply -f argocd/app-gami-dev.yaml
kubectl get application gami-dev -n argocd -w
```

---

## Deploying an app change to dev

Same pattern as staging — bump the image tag directly and push, no manual
release process:

```bash
cd overlays/dev
kustomize edit set image \
  ghcr.io/authenticmemory/gami-webapp=ghcr.io/authenticmemory/gami-webapp:<tag> \
  ghcr.io/authenticmemory/gami-webapp-migrate=ghcr.io/authenticmemory/gami-webapp:<tag>-migrate

git add kustomization.yaml
git commit -m "deploy: bump dev to <tag>"
git push
```

ArgoCD picks it up automatically. `gami-migrate` (PreSync hook) runs first;
the `gami-webapp` Deployment (single pod, dev-only) rolls out after.

---

## Verifying dev

```bash
kubectl get pods -n gami-dev
kubectl get application gami-dev -n argocd
kubectl get nodes -L env    # confirm the dev pod landed on the env=dev node
```

```bash
curl -Ik https://dev.authenticmemory.org
curl -Ik https://verify-dev.authenticmemory.org
```

Dev uses `letsencrypt-staging` too (same untrusted-but-functional-certs
reasoning as staging) — expect a cert warning in a normal browser, `curl -Ik`
skips it.

---

## Troubleshooting

Cluster-level issues (clock skew, ArgoCD login looping, Traefik entrypoint
collisions) are documented with exact symptoms and fixes in
[README-local.md](README-local.md)'s **Gotchas** section — read that first.

Dev-specific things to check:
- Dev's Postgres (`overlays/dev/postgres-cluster.yaml`) is a **single
  instance with no backup**, same as staging — intentional, not a bug.
- Since ArgoCD itself prefers the same node dev's workloads do
  (`env=dev`), a resource-starved dev node can affect ArgoCD's own
  responsiveness, not just dev's app pods — check `kubectl top node
  <dev-node>` if ArgoCD's UI feels slow, before assuming it's a dev app
  problem.
