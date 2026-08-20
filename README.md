# gami-infra

Infrastructure-as-code for the Gami / Authentic Memory platform. The
application code lives in a separate repo (`gami-app`); this one describes
how it's deployed and run.

Two Hetzner VPS nodes, each running its own independent single-node k3s
cluster. One ArgoCD instance lives on staging and manages both.

```
Terraform  →  networking + firewalls for 2 pre-existing servers
Ansible    →  installs k3s on each node, installs ArgoCD on staging,
              registers production with it
ArgoCD     →  watches this repo, applies base/ + overlays/ to both clusters
```

Day to day you change Kustomize manifests and push — ArgoCD does the rest.
Terraform and Ansible only run when the clusters themselves change.

---

## Credentials: `.env`

Every credential this repo needs is an environment variable. None are
committed. [`.env.example`](.env.example) is the complete list, with a note
on which tool reads each one and which are optional.

```bash
cp .env.example .env      # then fill in real values
set -a; source .env; set +a
```

Use exactly that `set -a` form. `export $(cat .env)` mangles any value
containing spaces and produces a confusing downstream failure — see
[troubleshooting.md](docs/troubleshooting.md). Note it also can't *unset* a
variable you blanked; open a fresh shell for that.

---

## Terraform

Attaches networking and firewalls to two **already-provisioned** Hetzner
servers. It never creates, resizes, or destroys them — a plan proposing to
touch a server means something is misconfigured.

It manages the private network staging's ArgoCD uses to reach production's
k3s API, plus the firewalls restricting SSH, the k3s API, and the ArgoCD UI
to your own IP.

```bash
set -a; source .env; set +a
cd terraform

terraform init \
  -backend-config="access_key=$HETZNER_S3_ACCESS_KEY" \
  -backend-config="secret_key=$HETZNER_S3_SECRET_KEY"

terraform plan     # read this before applying
terraform apply
```

More: [docs/terraform.md](docs/terraform.md).

---

## Ansible

Turns the two servers into clusters: OS hardening and an `ops` user, k3s on
each node independently, ArgoCD on staging, production registered as a
remote cluster, and the Secrets that can't live in git.

```bash
set -a; source .env; set +a
cd ansible

# First run against fresh servers — connect as root, install your key for `ops`
ansible-playbook -i inventory/production.yml playbooks/site.yml \
  -e ansible_user=root \
  -e ssh_public_key_path=~/.ssh/id_ed25519.pub

# Every run after that
ansible-playbook -i inventory/production.yml playbooks/site.yml
```

Idempotent — safe to re-run. Every play is tagged, so you rarely need a full
run:

```bash
ansible-playbook -i inventory/production.yml playbooks/site.yml --tags argocd
```

`baseline`, `k3s`, `secrets`, `app-secrets`, `ghcr`, `argocd`,
`register-prod`. `--list-tags` shows them; `--skip-tags` and `--limit` work
as usual.

There are also playbooks for database dumps, restores and backups
([docs/database.md](docs/database.md)) and day-2 OS maintenance
(`patch-os.yml`, `cleanup-logs.yml`).

More: [docs/setup-server.md](docs/setup-server.md).

---

## Documentation

| | |
|---|---|
| [Server setup](docs/setup-server.md) | Bootstrap the real infrastructure, start to finish |
| [Local install](docs/install-local.md) | Run the whole stack on your own machine |
| [Staging](docs/staging.md) | Deploying to and verifying staging |
| [Production](docs/production.md) | Releases, rollbacks, secrets |
| [Database](docs/database.md) | Dumps, restores, CNPG + S3 backups, PITR |
| [Architecture](docs/architecture.md) | What every directory is and why |
| [Troubleshooting](docs/troubleshooting.md) | Known failures, with fixes |
| [Terraform](docs/terraform.md) | Networking specifics |
| [Image pull secret](docs/image-pull-secret.md) | GHCR credentials |

New to the repo? Read [Architecture](docs/architecture.md) first.
