# Image pull secret (`ghcr-pull-secret`)

Every Deployment and Job in this repo references `imagePullSecrets: [{name:
ghcr-pull-secret}]`, but there's deliberately no manifest for it — a real
`.dockerconfigjson` is a long-lived registry credential, not an app secret
with its own rotation story, and shouldn't be committed even sealed.

Ansible creates it instead, from credentials that live only in your `.env`.

---

## Setup

```bash
# in .env
GHCR_USERNAME=<github-username>
GHCR_PAT=<fine-grained PAT, read:packages only>
```

```bash
set -a; source .env; set +a
cd ansible
ansible-playbook -i inventory/production.yml playbooks/site.yml --tags ghcr
```

[`roles/image_pull_secret`](../ansible/roles/image_pull_secret/) renders the
Secret and applies it to **both** clusters. It uses `kubectl apply`, so
re-running with a new PAT in `.env` is also how you rotate.

The role builds the dockerconfigjson from a template rather than shelling
out to `kubectl create secret docker-registry` — that would put the PAT in
the node's process table during the apply.

If `GHCR_PAT` is unset the role skips itself entirely and prints a warning,
so a run that forgot to source `.env` looks clean but changes nothing.

---

## Why it's per-cluster *and* per-namespace

`imagePullSecrets` is resolved in the **pod's own namespace** — a Secret in
another namespace, or on the other cluster, is invisible to it. So it exists
twice:

| Cluster | Namespace |
|---|---|
| staging | `gami-staging` |
| production | `gami` |

`site.yml` picks the right one per host. It's also why the role creates the
namespace if missing: ArgoCD's Applications set `CreateNamespace=true`, but
Ansible runs *before* ArgoCD's first sync.

---

## When you don't need it

Only if the GHCR **packages** are public. That's a separate GitHub setting
from repository visibility — a public repo still publishes private packages
by default. Check with a logged-out pull:

```bash
docker pull ghcr.io/authenticmemory/gami-webapp:<some-tag>
```

If that succeeds anonymously, leave `GHCR_PAT` unset and drop the
`imagePullSecrets` blocks from `base/gami-webapp/deployment.yaml` and
`base/gami-migrate-job.yaml`. If it 401s, keep this as-is.

---

## Rotating by hand

If you need it applied immediately without a playbook run, note that
`kubectl create secret` fails when the Secret already exists — use
create-and-apply:

```bash
umask 077
GHCR_USER=<github-username>
read -rs GHCR_PAT        # paste the token; it won't echo or reach history

printf '{"auths":{"ghcr.io":{"username":"%s","password":"%s","auth":"%s"}}}' \
  "$GHCR_USER" "$GHCR_PAT" \
  "$(printf '%s:%s' "$GHCR_USER" "$GHCR_PAT" | base64 -w0)" > /tmp/ghcr.json

sudo k3s kubectl create secret generic ghcr-pull-secret \
  --namespace gami-staging \
  --type=kubernetes.io/dockerconfigjson \
  --from-file=.dockerconfigjson=/tmp/ghcr.json \
  --dry-run=client -o yaml | sudo k3s kubectl apply -f -

rm -f /tmp/ghcr.json
unset GHCR_PAT
```

Running pods won't pick up a new pull secret until they restart. Use
`kubectl delete pod -l app=gami-webapp` rather than `rollout restart`, which
ArgoCD treats as drift.

---

## Related

- [Troubleshooting](troubleshooting.md) — `ImagePullBackOff`
- [Server setup](setup-server.md)
