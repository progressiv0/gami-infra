# Local deployment guide

Run the full stack — k3s, ArgoCD, and (optionally) the app itself — on a
machine you control directly, without touching Hetzner or any cloud account.

There's exactly one path now: a **single machine, mirroring staging
exactly.** Single-node k3s, CNPG Postgres (`instances: 1`, no backup), and
`argocd/app-gami-staging.yaml` applied locally against
`overlays/staging`/`app-gami-cluster-wide-staging.yaml`/`app-cluster-operators-staging.yaml`
— the same manifests that run on the real staging node, just pointed at
your local cluster instead. There's no second cluster on a local rig, so
nothing gets registered as an ArgoCD remote cluster (that only matters for
staging→production, see [README.md](README.md)'s "Node topology" section).

Uses `ansible/inventory/local.yml` (`ansible_connection: local`) +
`ansible/playbooks/local.yml`.

Terraform is **not used** for local — you already have the machine.
Everything from "install k3s" onward is identical in shape to staging;
only the inventory differs.

---

## Prerequisites

- One Linux VM/machine you can run Ansible against as `root` (or a user
  with passwordless sudo) — this can be the machine you're running Ansible
  from itself (`ansible_connection: local`), no separate SSH target needed.
- Outbound internet access (to fetch the k3s install script, container
  images, and CNI plugins).

### Installing Ansible

If your control machine doesn't have Ansible, and installing the distro
package would force an incompatible Python upgrade, use an isolated
virtualenv instead of fighting the system package manager:

```bash
python3 -m venv ~/.ansible-venv
~/.ansible-venv/bin/pip install --quiet ansible-core
~/.ansible-venv/bin/ansible-galaxy collection install community.general ansible.posix
```

Use `~/.ansible-venv/bin/ansible-playbook` in place of `ansible-playbook`
everywhere below.

### `ansible.cfg` inventory gotcha

This repo's `ansible/ansible.cfg` defaults to `inventory/production.yml`
(the real static inventory). Point at the local one explicitly instead of
relying on the default:

```bash
export ANSIBLE_HOST_KEY_CHECKING=False   # convenient for a throwaway local rig; don't rely on this for anything long-lived
```

---

## Running the local playbook

```bash
cd gami-infra/ansible
ansible-playbook -i inventory/local.yml playbooks/local.yml
```

This playbook, in order:
1. Runs the `node_baseline` role (apt/ufw hardening — this assumes a
   Debian/Ubuntu host; adjust if you're on something else).
2. Installs k3s via the `k3s_server` role's single-node
   `--cluster-init` bootstrap (embedded etcd, nothing to join — there's
   only one node).
3. Installs ArgoCD via the `argocd` role, with `argocd_local_apps`
   overridden to the same staging-mirroring set
   (`app-cluster-operators-staging.yaml`, `app-gami-cluster-wide-staging.yaml`,
   `app-gami-staging.yaml`) and `argocd_remote_apps: []` — nothing to
   register remotely on a single-node local rig.

Expect this to take a few minutes — it downloads and installs k3s, waits for
the node to report `Ready`, then installs the full ArgoCD stack plus the
cluster operators (cert-manager, CNPG, Sealed Secrets).

**This is genuinely idempotent** — re-running it against an
already-bootstrapped machine is a no-op (`ok=` rather than `changed=` for
most tasks), which is also how you'd apply role changes without tearing
anything down.

**Known limitation, carried over from this rig's earlier dev-mirroring
design**: `overlays/staging`'s Ingress/cert-manager config targets the real
`staging.authenticmemory.org`/`verify-staging.authenticmemory.org`
hostnames and the Let's Encrypt **staging** ACME solver — neither resolves
or verifies against a machine that isn't actually reachable at those
hostnames. The `cm-acme-http-solver` pod will sit there failing forever and
the `Certificate` will stay `READY: False`. This is harmless and expected
for local use — the Ingress health-check override below means it doesn't
block anything else in the sync chain — or work around it with `/etc/hosts`
+ `kubectl port-forward` to reach the app directly, or the self-signed
`ClusterIssuer` workaround in the Gotchas section below.

---

## Gotchas hit while building this (read before you debug the same thing)

These are real failures encountered running this exact process, kept here so
you recognize them immediately instead of re-diagnosing from scratch.

### Gotcha: clock skew

**Symptom**: `kubectl get nodes` shows `AGE` as `<invalid>`; Traefik's
`helm-install-traefik` job (or any other job needing a ServiceAccount token)
fails with `Kubernetes cluster unreachable: the server has asked for the
client to provide credentials`, and this failure repeats forever
(`CrashLoopBackOff`) even though the API server itself is healthy.

**Cause**: bearer/JWT token validation fails under clock skew. This is most
likely on a VM whose hypervisor time sync is off or disabled — a guest
clock that's drifted even an hour or two ahead is enough, and some minimal
`ntpd` builds can't self-correct a jump that large.

**Fix**:
1. Confirm the actual authoritative time (e.g. `curl -sI https://example.com
   | grep -i ^date:` from a machine with internet access) and compare
   against `date -u` locally.
2. Enable your hypervisor's guest time sync if you're on a VM (e.g.
   `vmware-toolbox-cmd timesync enable` on VMware Tools) and **disable any
   guest-side NTP daemon** running alongside it — running both
   simultaneously causes them to fight each other.
3. For an immediate correction (don't wait for periodic sync), set the clock
   directly using a fetched, trusted timestamp, e.g.:
   ```bash
   EPOCH=$(curl -sI https://example.com | grep -i '^date:' | sed 's/^[Dd]ate: //' | tr -d '\r' \
     | xargs -I{} python3 -c "import email.utils; print(int(email.utils.parsedate_to_datetime('{}').timestamp()))")
   date -u -s @$EPOCH
   ```
4. Re-check credential-dependent jobs — they should recover once time is
   sane (a pod/job restart may be needed if it's stuck `CrashLoopBackOff`).

### Gotcha: ArgoCD login loops back to the login screen

**Symptom**: entering the correct admin username/password appears to
process, then bounces straight back to the login screen with no visible
error.

**Cause**: `argocd-server` logs (`kubectl logs -n argocd -l
app.kubernetes.io/name=argocd-server`) show `invalid session: account
password has changed since token issued` on every request right after a
successful login. This happens when the `argocd-secret`'s
`admin.passwordMtime` field holds a timestamp **later than the current real
time** — which happens if that field got written while the clock was still
skewed (see above). Since no valid session token can ever have an "issued
at" time later than a future `passwordMtime`, login becomes permanently
impossible until real time catches up or the field is fixed directly.

**Fix** (once clocks are correct):
```bash
kubectl patch secret argocd-secret -n argocd --type=json \
  -p='[{"op":"remove","path":"/data/admin.passwordMtime"}]'
kubectl rollout restart deployment argocd-server -n argocd
```
This doesn't change the admin password — `argocd-server` regenerates
`passwordMtime` correctly (matching real current time) on next reconcile.

### Gotcha: Traefik custom entrypoint port collides with a built-in one

If you add a custom Traefik entrypoint (like the ArgoCD one this repo adds),
picking a **container port** that Traefik's chart already uses internally
(e.g. `8443`, which `websecure` already claims — externally mapped to 443)
causes `CrashLoopBackOff`: `error opening listener: listen tcp :8443: bind:
address already in use`. Use a genuinely free container port (this repo uses
`9443` internally, exposed externally as `8443` via `exposedPort`).

Also: a Traefik custom port needs `expose: default: true` in the
`HelmChartConfig` values to actually get added to the Service's exposed
ports — without it, the entrypoint works inside the pod but nothing outside
the cluster can reach it.

### Gotcha: ArgoCD sync stuck forever on "waiting for healthy state of ... Ingress"

Symptom: an Application's sync operation never finishes — `kubectl get
application <name> -n argocd -o jsonpath='{.status.operationState.message}'`
shows `waiting for healthy state of networking.k8s.io/Ingress/<name>`
indefinitely, blocking every sync-wave after the Ingress (in this repo,
that means `gami-migrate` and the rest of the Deployment never even get
created).

Cause: ArgoCD's built-in health check for `Ingress` expects
`.status.loadBalancer.ingress` to be populated — the IP/hostname a cloud
LoadBalancer would assign. Traefik running in host-network mode (this
repo's k3s setup, `servicelb` disabled — see
`ansible/roles/k3s_server/defaults/main.yml`) never populates that field
for any Ingress, so ArgoCD considers every Ingress here permanently
unhealthy. This isn't a local-only quirk — it happens on the real staging
and production nodes with this same Traefik configuration too.

Fix: add a `resource.customizations.health.networking.k8s.io_Ingress` Lua
override to `argocd-cm` that treats an Ingress as healthy once it exists,
without checking `loadBalancer` status. This repo's `argocd` Ansible role
does this automatically (`files/ingress-health-check.lua` +
the "Patch argocd-cm with the Ingress health check override" task) — if
you're seeing this on a cluster bootstrapped before that task existed,
re-run `local.yml`, or apply the patch by hand:
```bash
kubectl patch configmap argocd-cm -n argocd --type merge \
  --patch-file ansible/roles/argocd/files/ingress-health-check.lua
# (wrap the file's content under the right YAML key first — see the Ansible
# task for the exact patch shape; a raw Lua file isn't a valid patch on its own)
```

### Gotcha: cert-manager can't issue real certs on a local/private network

If your Ingress hostname (`staging.authenticmemory.org`) doesn't have real
DNS pointing at your local machine, cert-manager's Let's Encrypt HTTP-01
challenge can never complete — the `cm-acme-http-solver` pod runs forever,
the `Certificate` stays `READY: False`, and (before the health-check fix
above existed) this used to block the whole sync-wave chain too. For local
testing, point the Ingress at a self-signed `ClusterIssuer` instead:
```bash
kubectl apply -f - <<EOF
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
This is a live, out-of-band patch for local testing only — don't commit it
to the real overlay. ArgoCD's `selfHeal: true` will revert the annotation
back to the committed `letsencrypt-staging` value on its next sync; that's
expected and fine once the Ingress health check fix above means it no
longer blocks anything either way.

### Gotcha: CNPG Cluster gets wedged after a storage-related failure

If the Postgres `Cluster`'s `initdb` Job hits `BackoffLimitExceeded` for any
storage-related reason (PVC stuck pending, disk full, etc.), CNPG can get
its own state tracking wedged even after the underlying cause is fixed
(`STATUS: Cluster is unrecoverable and needs manual intervention`). Deleting
just the stuck pod or Job usually isn't enough — delete the whole `Cluster`
object (and its PVC, if orphaned: `kubectl delete pvc <name> -n
gami-staging`) and let CNPG recreate it from scratch.

---

## Verifying the cluster

```bash
# Point kubectl at the new cluster (k3s writes its own kubeconfig):
sudo cat /etc/rancher/k3s/k3s.yaml > /tmp/k3s.yaml
export KUBECONFIG=/tmp/k3s.yaml

kubectl get nodes -o wide          # should show STATUS Ready
kubectl get pods -A                # nothing should be stuck outside Running/Completed
kubectl get pods -n argocd         # full argocd-* stack should be Running
```

### Accessing the ArgoCD UI

The `argocd` Ansible role exposes ArgoCD through Traefik on a dedicated
NodePort (`30443` by default — see `ansible/roles/argocd/defaults/main.yml`'s
`argocd_ingress_port` and `files/traefik-argocd-entrypoint.yaml`'s pinned
`nodePort`):

```
https://<machine-ip>:30443/
```

Your browser will warn about the self-signed cert — expected for local use,
proceed anyway.

Get the initial admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Username is `admin`. Change the password (or delete
`argocd-initial-admin-secret`) after first login, same as you would for any
ArgoCD install.

**Alternative for a quick one-off check** (no Traefik involved, doesn't need
the port exposed): `kubectl port-forward svc/argocd-server -n argocd
8443:443`, then browse to `https://localhost:8443`.

---

## Deploying the app itself locally

The `argocd` role already applies `app-gami-staging.yaml`, which points at
`overlays/staging` in **this repo's real GitHub remote** — not useful for a
local test cluster unless you actually want it tracking the real repo.

For genuinely local app testing, either:
- Point a test `Application` at your local repo checkout / a fork, with your
  own hostnames, instead of using the committed `argocd/app-gami-staging.yaml`
  as-is; or
- Skip ArgoCD for this and `kubectl apply -k overlays/staging` directly
  against your local cluster to render and apply the Kustomize output once,
  without GitOps auto-sync. (`overlays/production/database`,
  `overlays/production/webapp` work the same way if you want to test one of
  those locally instead.)

Either way, remember the app itself needs:
- `ghcr-pull-secret` created manually (see
  `base/README-image-pull-secret.md`) — nothing pulls without it.
- **cert-manager, CNPG, and Sealed Secrets** — if `argocd/`'s manifests were
  applied (either via the `argocd` role or by hand), these install
  themselves automatically through `argocd/app-cluster-operators-staging.yaml`
  (see [README.md](README.md)'s `cluster-operators/` section) — no separate
  step needed. If you skipped ArgoCD entirely and only ran `kubectl apply -k
  overlays/...` directly, you'll need to apply `cluster-operators/cert-manager`,
  `cluster-operators/cnpg`, and `cluster-operators/sealed-secrets` yourself
  the same way (`kubectl apply -k cluster-operators/cnpg --server-side` —
  CNPG's CRDs are too large for client-side apply, see that Kustomization's
  own comments). Postgres storage itself needs nothing extra either way —
  everything uses k3s's bundled `local-path` storage class.
- **The Sealed Secrets controller** — also GitOps-managed
  (`cluster-operators/sealed-secrets/`), applied automatically alongside the
  others. It lands in `kube-system`, not its own namespace — the upstream
  manifest hardcodes that. Regardless of whether it's automatic or applied
  by hand, real secrets still need to be sealed via the bootstrap runbook
  described in [README-staging.md](README-staging.md) —
  `overlays/staging/sealed-secrets/` is empty `resources: []` until you do
  this.
- The **Barman Cloud plugin** is not part of staging's operator set at all
  (staging has no backup) — only relevant if you're testing
  `overlays/production/database` locally, where it's also GitOps-managed
  (`cluster-operators/cnpg-barman-plugin/`).

For a local smoke test, it's usually far simpler to run the app via its own
`docker-compose.yml` (in the `gami-app` repo) than to stand up the full
CNPG/SealedSecrets chain locally — this repo's local path is mainly
useful for testing **infrastructure** changes (Ansible roles, Kustomize
overlays, ArgoCD wiring), not for day-to-day app development.

---

## Tearing down / starting over

```bash
sudo k3s-uninstall.sh
```

Then re-run `ansible-playbook -i inventory/local.yml playbooks/local.yml`.
