# Local install

Run the whole stack — k3s, ArgoCD, the cluster operators — on a machine you
control, without touching Hetzner or any cloud account.

The local rig **mirrors staging exactly**: single-node k3s, the same
`overlays/staging` manifests, the same Applications. There's no second
cluster, so nothing gets registered as an ArgoCD remote.

Terraform isn't used at all — you already have the machine.

This is mainly useful for testing **infrastructure** changes (Ansible roles,
Kustomize overlays, ArgoCD wiring). For day-to-day app development, running
`gami-app`'s own `docker-compose.yml` is far simpler than standing up the
full operator chain locally.

---

## Prerequisites

- One Linux VM or machine you can run Ansible against as `root` (or with
  passwordless sudo). It can be the same machine you run Ansible *from* —
  `inventory/local.yml` uses `ansible_connection: local`.
- Outbound internet (k3s install script, container images, CNI plugins).

If installing Ansible from your distro's packages would force an
incompatible Python upgrade, use a virtualenv instead of fighting the
package manager:

```bash
python3 -m venv ~/.ansible-venv
~/.ansible-venv/bin/pip install --quiet ansible-core
~/.ansible-venv/bin/ansible-galaxy collection install community.general ansible.posix
```

Then use `~/.ansible-venv/bin/ansible-playbook` below.

---

## Step by step

### 1. Run the playbook

`ansible.cfg` defaults to the *production* inventory, so point at the local
one explicitly:

```bash
cd ansible
ansible-playbook -i inventory/local.yml playbooks/local.yml
```

That runs the OS baseline, installs single-node k3s, then installs ArgoCD
with `argocd_local_apps` pointed at the staging-mirroring set and
`argocd_remote_apps: []`.

Expect a few minutes. It's genuinely idempotent — re-running against an
already-bootstrapped machine is how you apply role changes without tearing
anything down.

### 2. Point kubectl at it

```bash
sudo cat /etc/rancher/k3s/k3s.yaml > /tmp/k3s.yaml
export KUBECONFIG=/tmp/k3s.yaml

kubectl get nodes -o wide     # STATUS Ready
kubectl get pods -A           # nothing stuck outside Running/Completed
```

### 3. Open the ArgoCD UI

```
https://<machine-ip>:30443/
```

Self-signed cert warning is expected locally.

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Username `admin`. For a quick check without Traefik:
`kubectl port-forward svc/argocd-server -n argocd 8443:443`, then
`https://localhost:8443`.

### 4. Tearing down

```bash
sudo k3s-uninstall.sh
```

Then re-run step 1.

---

## Expected limitation: certificates won't issue

`overlays/staging`'s Ingress targets the real
`staging.authenticmemory.org` hostnames and Let's Encrypt. Neither resolves
to your machine, so the `cm-acme-http-solver` pod fails forever and the
`Certificate` stays `READY: False`.

This is harmless — the Ingress health-check override the `argocd` role
installs means it doesn't block anything else in the sync chain. Work
around it with `/etc/hosts` + `kubectl port-forward`, or point the Ingress
at a self-signed issuer for local testing:

```bash
kubectl apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-local-test
spec:
  selfSigned: {}
EOF

kubectl annotate ingress gami-webapp -n gami-staging \
  cert-manager.io/cluster-issuer=selfsigned-local-test --overwrite
kubectl delete certificate gami-webapp-tls -n gami-staging
kubectl delete secret gami-webapp-tls -n gami-staging
```

Don't commit that. ArgoCD's `selfHeal` reverts the annotation on its next
sync, which is fine.

---

## Running the app itself locally

The `argocd` role applies `app-gami-staging.yaml`, which points at this
repo's **real GitHub remote** — not useful for local testing unless you
actually want it tracking the real repo. Two alternatives:

- Point a test `Application` at your own fork or local checkout, with your
  own hostnames.
- Skip ArgoCD and render directly: `kubectl apply -k overlays/staging`.

Either way the app needs:

- **`ghcr-pull-secret`** in the `gami-staging` namespace, unless the GHCR
  packages are public — see [image-pull-secret.md](image-pull-secret.md).
  Nothing pulls without it.
- **The cluster operators.** If `argocd/`'s manifests were applied, these
  install themselves through `app-cluster-operators-staging.yaml`. If you
  skipped ArgoCD entirely, apply them yourself — note CNPG needs
  server-side apply, its CRDs are too large for client-side:
  ```bash
  kubectl apply -k cluster-operators/cert-manager
  kubectl apply -k cluster-operators/cnpg --server-side
  ```
- **Postgres storage** needs nothing extra — k3s's bundled `local-path`
  handles it.

Staging's Secrets are generated on the cluster by the `app_secrets` role, so
there's no sealing step. The Barman backup plugin isn't part of staging's
operator set at all.

---

## Related

- [Troubleshooting](troubleshooting.md) — clock skew, ArgoCD login loops,
  Traefik port collisions, wedged CNPG clusters. Most local failures are
  documented there.
- [Architecture](architecture.md) — what the pieces are
- [Server setup](setup-server.md) — the real-infrastructure equivalent
