# `ghcr-pull-secret`

Every Deployment/Job in this repo references `imagePullSecrets: [{name:
ghcr-pull-secret}]`, but there's deliberately no `image-pull-secret.yaml` here
— a real `.dockerconfigjson` credential is not something to commit to git,
even encrypted-at-rest-adjacent via Sealed Secrets (it's a long-lived registry
credential, not an app secret with its own rotation story).

It is created by Ansible instead, from credentials that live only in your
`.env` and never enter git — the same model
`ansible/roles/argocd/tasks/repo-credentials.yml` uses:

```bash
# in .env
GHCR_USERNAME=<github-username>
GHCR_PAT=<fine-grained PAT, read:packages only>
```

```bash
set -a; source .env; set +a
cd ansible
ansible-playbook -i inventory/production.yml playbooks/site.yml
```

`ansible/roles/image_pull_secret` renders the Secret and applies it to **both**
clusters. It uses `kubectl apply`, so re-running with a new PAT in `.env` is
also how you rotate the credential.

## Why it's per-cluster *and* per-namespace

`imagePullSecrets` is resolved in the **pod's own namespace** — a Secret in
another namespace, or on the other cluster, is invisible to it. So this Secret
exists twice, once in each environment's app namespace:

| Cluster | Namespace | Set by |
| --- | --- | --- |
| staging | `gami-staging` | `overlays/staging/kustomization.yaml`'s `namespace:` |
| production | `gami` | `base/kustomization.yaml`'s `namespace:` |

`playbooks/site.yml` picks the right one per host. This is also why the role
creates the namespace if it's missing: ArgoCD's Applications set
`CreateNamespace=true`, but Ansible runs *before* ArgoCD's first sync.

## When you don't need it at all

Only if the GHCR **packages** are public. That's a separate GitHub setting
from repository visibility — a public repo still publishes private packages by
default. Check with a logged-out pull:

```bash
docker pull ghcr.io/authenticmemory/gami-webapp:<some-tag>
```

If that succeeds anonymously, leave `GHCR_PAT` unset (the role skips itself)
and drop the `imagePullSecrets` blocks from `base/gami-webapp/deployment.yaml`
and `base/gami-migrate-job.yaml`. If it 401s, keep this as-is.
