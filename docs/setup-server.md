# Server setup

Bootstrapping the real infrastructure: two Hetzner servers → two k3s
clusters → ArgoCD managing both.

This is done **once, for both environments**. Running staging's bootstrap
also brings production's ArgoCD management online — there is no separate
"production bootstrap."

If the infrastructure already exists, you want [staging.md](staging.md) or
[production.md](production.md) instead.

---

## Before you start

- Two **already-provisioned** Hetzner servers named `gami-staging` and
  `gami-prod`. Terraform does not create them.
- Root SSH access to both, from however they were provisioned. Ansible
  creates the non-root `ops` user on the first run, but that first
  connection lands as `root`.
- A Hetzner Cloud API token, and an Object Storage bucket `gami-tfstate`
  created out of band (Terraform's backend won't create its own bucket)
  with access keys for it.
- `terraform` (>= 1.7), `ansible-core`, and `kubectl` locally.
- `.env` filled in — see [`.env.example`](../.env.example) for the full list.

---

## Step by step

### 1. Fill in `.env`

```bash
cp .env.example .env
# edit .env
set -a; source .env; set +a
```

### 2. Terraform — networking and firewalls

```bash
cd terraform
terraform init \
  -backend-config="access_key=$HETZNER_S3_ACCESS_KEY" \
  -backend-config="secret_key=$HETZNER_S3_SECRET_KEY"
terraform plan
```

**Read the plan.** It should propose: two `data "hcloud_server"` reads (no
creates), one network + subnet for `gami-argocd-link` (`10.10.0.0/24`), two
address pinnings (staging `.2`, prod `.3`), and three firewalls. **No
`hcloud_server` resource should appear** — if one does, a `nodes` entry's
`name` doesn't match the real server name.

```bash
terraform apply
```

### 3. Ansible — clusters and ArgoCD

The very first run must connect as `root` and pass a public key to install
for the `ops` user it creates — otherwise `ops` has no key and you're locked
out of it:

```bash
cd ../ansible
ansible-playbook -i inventory/production.yml playbooks/site.yml \
  -e ansible_user=root \
  -e ssh_public_key_path=~/.ssh/id_ed25519.pub
```

Every run after that drops both overrides:

```bash
ansible-playbook -i inventory/production.yml playbooks/site.yml
```

This runs, in order: OS baseline on both nodes → k3s on both nodes
independently → staging's application Secrets → the GHCR pull secret on both
→ ArgoCD on staging → production registered as a remote cluster.

Confirm both came up (two separate API servers — there's no single command
showing both):

```bash
KUBECONFIG=<staging kubeconfig> kubectl get nodes
KUBECONFIG=<prod kubeconfig> kubectl get nodes
```

### 4. Reach the ArgoCD UI

Staging only — there's no ArgoCD on production.

```
https://<gami-staging public IP>:30443
```

That port is open only to `TF_VAR_admin_ip_cidr`, at both the Hetzner
firewall and ufw. Expect a browser certificate warning: the IngressRoute uses
a bare `tls: {}`, so Traefik serves its own self-signed cert. That's
expected.

```bash
KUBECONFIG=<staging kubeconfig> kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Username `admin`. Change it after first login.

If your IP rotates you lose both the UI and SSH until a `terraform apply`
with the new CIDR. An SSH tunnel avoids depending on that:
`ssh -L 8080:localhost:30443 ops@<staging IP>`, then `https://localhost:8080`.

Under **Settings → Clusters** you should see both `in-cluster` (staging) and
`prod`.

### 5. Confirm the operators installed themselves

cert-manager, CNPG, Sealed Secrets and the Barman plugin are all ArgoCD
Applications — no manual install. Just check they arrived:

```bash
KUBECONFIG=<staging kubeconfig> kubectl get applications -n argocd
KUBECONFIG=<prod kubeconfig> kubectl get pods -n cert-manager
KUBECONFIG=<prod kubeconfig> kubectl get pods -n cnpg-system
```

---

## What you still have to do manually

Everything above is automated. These are not — each for a specific reason.

### Production's S3 backup credentials

A long-lived storage credential, never committed:

```bash
sudo k3s kubectl create secret generic gami-postgres-backup-creds \
  --namespace gami \
  --from-literal=ACCESS_KEY_ID="<Hetzner Object Storage access key>" \
  --from-literal=ACCESS_SECRET_KEY="<Hetzner Object Storage secret key>"
```

Then prove the whole backup path works rather than waiting for 02:00:

```bash
ansible-playbook -i inventory/production.yml playbooks/db-backup.yml
```

See [database.md](database.md).

### Production's sealed secrets

Production seals `gami-secrets` and `gami-smtp` into git, against
production's **own** Sealed Secrets controller (staging's keypair is
different and cannot decrypt them). See [production.md](production.md).

### Real SMTP values for production

`overlays/production/webapp/kustomization.yaml`'s `configMapGenerator` ships
placeholders (`SMTP_HOST=smtp.example.com`). Replace before the first real
deploy.

### DNS

Point `app.` / `verify.` at production and `staging.` /
`verify-staging.` at staging. cert-manager's HTTP-01 challenge can't
complete until DNS resolves to the right node.

### `--tls-san` if you add a private network later

k3s bakes its API server certificate SANs at install time. If a private
network is created *after* k3s was installed, that node's certificate won't
cover its private address and ArgoCD's connection to it fails TLS
verification. A from-scratch install handles this automatically
([`cluster-init.yml`](../ansible/roles/k3s_server/tasks/cluster-init.yml)
reads `argocd_link_ip` from the inventory); an existing node needs the
`--tls-san` fix in [troubleshooting.md](troubleshooting.md).

**After any manual k3s restart, restart CoreDNS too** — its watch against
the API server can wedge, leaving every Service name unresolvable
clusterwide. This has bitten us; see
[troubleshooting.md](troubleshooting.md).

---

## Editing `argocd/*.yaml` later

Worth knowing before it confuses you: the files in `argocd/` are applied by
Ansible, **not** watched by ArgoCD. Editing one and pushing changes nothing
on the cluster.

```bash
ansible-playbook -i inventory/production.yml playbooks/site.yml --tags argocd
ansible-playbook -i inventory/production.yml playbooks/site.yml --tags register-prod
```

Everything under `overlays/` and `cluster-operators/apps-*/` does sync
automatically.

---

## Related

- [Architecture](architecture.md) — what each piece is
- [Staging](staging.md) / [Production](production.md) — day-to-day use
- [Database](database.md) — backups and restores
- [Troubleshooting](troubleshooting.md) — when the above doesn't go to plan
