# Local deployment guide

Run the full stack — k3s, ArgoCD, and (optionally) the app itself — on
machines you control directly, without touching Hetzner or any cloud
account. Two supported shapes:

- **Single machine** — one Linux box (bare metal or one VM), everything on
  it. Uses `ansible/inventory/local.yml` + `ansible/playbooks/local.yml`.
- **3-node local cluster** — three VMs (e.g. local VMware/VirtualBox/KVM
  guests) wired together like production, for testing the real multi-node
  HA behavior (embedded etcd quorum, pod scheduling across nodes). Uses
  `ansible/inventory/alpine-local.yml` + `ansible/playbooks/alpine-local.yml`.
  This is what was actually built and verified step-by-step to write this
  guide.

Terraform is **not used** for local — you already have the machines (or
create them yourself in whatever hypervisor you have). Everything from
"install k3s" onward is identical in shape to staging/production; only the
inventory and a couple of skipped steps differ.

---

## Prerequisites

- One or more Linux VMs/machines you can SSH into as `root` (or a user with
  passwordless sudo). This guide was built and tested against **Alpine
  Linux** guests on VMware — adjust package-manager commands if you're on
  Debian/Ubuntu instead (see the callouts below).
- SSH key-based access already working to every node (`ssh <host>` with no
  password prompt).
- Outbound internet access from each node (to fetch the k3s install script,
  container images, and CNI plugins).
- A machine to run Ansible from — this can be one of the cluster nodes
  itself, or a separate control machine with SSH reachability to all nodes.

### Installing Ansible

If your control machine doesn't have Ansible, and installing the distro
package would force an incompatible Python upgrade (this happened on Alpine —
the `ansible` apk package required `python3~3.14`, but the system was on
3.12), use an isolated virtualenv instead of fighting the system package
manager:

```bash
python3 -m venv ~/.ansible-venv
~/.ansible-venv/bin/pip install --quiet ansible-core
~/.ansible-venv/bin/ansible-galaxy collection install community.general ansible.posix
```

Use `~/.ansible-venv/bin/ansible-playbook` in place of `ansible-playbook`
everywhere below.

### `ansible.cfg` inventory plugin gotcha

This repo's `ansible/ansible.cfg` restricts enabled inventory plugins to only
`hetzner.hcloud.hcloud` (needed for the real `inventory/hcloud.yml`). That
means Ansible will refuse to load a plain static YAML inventory file
(`local.yml`, `alpine-local.yml`) unless you widen it for your local run —
without editing the checked-in config, export this first:

```bash
export ANSIBLE_INVENTORY_ENABLED=yaml,host_list,ini,auto
export ANSIBLE_HOST_KEY_CHECKING=False   # convenient for a throwaway local rig; don't rely on this for anything long-lived
```

---

## Path A — Single machine

Uses `ansible/inventory/local.yml` (targets `localhost` directly,
`ansible_connection: local`) and `ansible/playbooks/local.yml`.

```bash
cd gami-infra/ansible
export ANSIBLE_INVENTORY_ENABLED=yaml,host_list,ini,auto

ansible-playbook -i inventory/local.yml playbooks/local.yml
```

This playbook, in order:
1. Runs the `node-baseline` role (apt/ufw hardening — **this assumes a
   Debian/Ubuntu host**; if you're on something else, see Path B, which
   skips this role entirely).
2. Installs k3s via the `k3s-server` role's `cluster-init.yml` tasks
   (single-node embedded-etcd bootstrap — there's nothing to join since
   there's only one node).
3. Installs ArgoCD via the `argocd` role.

When it finishes, skip to [Verifying the cluster](#verifying-the-cluster)
below.

---

## Path B — 3-node local cluster (what this guide was built against)

This is the more useful path for actually exercising the HA design (embedded
etcd quorum, multi-node scheduling) without touching Hetzner. The steps below
are exactly what was run to validate this repo's Ansible roles end-to-end —
including the real bugs hit and fixed along the way, documented so you don't
have to rediscover them.

### 1. Provision 3 VMs yourself

Outside this repo's scope — use whatever hypervisor you have (VMware,
VirtualBox, KVM, Proxmox...). You need 3 Linux VMs on the same network,
reachable by IP, with SSH key access. This guide's reference environment was
3 Alpine Linux VMware guests on a private `192.168.253.0/24` network.

**If your VMs are on VMware**: enable VMware Tools time sync on every node.
Guest clocks on hypervisors drift, sometimes by hours, if this is off — and
clock skew causes deeply confusing failures later (see the
[Clock skew](#gotcha-clock-skew-on-vmware-guests) section below, which
documents a real multi-hour drift this exact setup hit).

```bash
# on each node:
vmware-toolbox-cmd timesync enable
vmware-toolbox-cmd timesync status   # should print "Enabled"
```

### 2. Set up SSH access

Add each node to your SSH config for convenience (adjust names/IPs/key path):

```
# ~/.ssh/config
Host node-a
    Hostname      192.168.x.x
    User          root
    IdentityFile  ~/.ssh/your_key
    IdentitiesOnly yes
Host node-b
    Hostname      192.168.x.x
    User          root
    IdentityFile  ~/.ssh/your_key
    IdentitiesOnly yes
Host node-c
    Hostname      192.168.x.x
    User          root
    IdentityFile  ~/.ssh/your_key
    IdentitiesOnly yes
```

Confirm all three are reachable: `ssh node-a hostname`, etc.

### 3. Write a static inventory

`ansible/inventory/alpine-local.yml` is the reference example — copy/adapt
it for your own node names/IPs:

```yaml
all:
  children:
    k3s_server:
      hosts:
        node-a:
          ansible_host: 192.168.x.x
        node-b:
          ansible_host: 192.168.x.x
        node-c:
          ansible_host: 192.168.x.x
  vars:
    ansible_user: root
    ansible_ssh_private_key_file: ~/.ssh/your_key
    ansible_python_interpreter: /usr/bin/python3
```

The group name (`k3s_server`) matters — `playbooks/site.yml`/`alpine-local.yml`
target that group name, same as production's dynamic `hcloud.yml` inventory.

### 4. Use (or copy) the local playbook

`ansible/playbooks/alpine-local.yml` mirrors `site.yml`'s structure (pin the
first node alphabetically as the bootstrap node, `cluster-init` on it, `join`
on the rest, then install ArgoCD) but **deliberately skips the
`node-baseline` role** — that role runs `apt`/`ufw`, which don't exist on
Alpine (or whatever non-Debian OS you're testing against). If your local VMs
are Debian/Ubuntu, you can use `site.yml` directly against your static
inventory instead and get `node-baseline` too.

Run it:

```bash
cd gami-infra/ansible
export ANSIBLE_INVENTORY_ENABLED=yaml,host_list,ini,auto
export ANSIBLE_HOST_KEY_CHECKING=False

ansible-playbook -i inventory/alpine-local.yml playbooks/alpine-local.yml --syntax-check
ansible-playbook -i inventory/alpine-local.yml playbooks/alpine-local.yml
```

Expect this to take several minutes — it downloads and installs k3s on all 3
nodes, waits for each to report `Ready`, then installs the full ArgoCD stack.
A clean run ends with a `PLAY RECAP` showing `failed=0` for every host.

**This is genuinely idempotent** — re-running it against an already-bootstrapped
cluster is a no-op (`ok=` rather than `changed=` for most tasks), which is
also how you'd apply role changes without tearing anything down.

---

## Gotchas hit while building this (read before you debug the same thing)

These are real failures encountered running this exact process, kept here so
you recognize them immediately instead of re-diagnosing from scratch.

### Ansible/YAML syntax bugs fixed in this repo

If you're running an ansible-core version newer than whatever this was
originally authored against, you may hit (these are already fixed in the
current `ansible/` tree, but are worth knowing about if you see them
resurface after an edit):

- **`delegate_to` on `include_role` at the task level** isn't accepted by
  modern ansible-core (`'delegate_to' is not a valid attribute for a
  IncludeRole`). Fix: wrap the `include_role` in a `block:` and put
  `delegate_to` on the block instead.
- **`ansible.builtin.authorized_key` doesn't exist** — that module is
  `ansible.posix.authorized_key`. Requires `ansible-galaxy collection install
  ansible.posix`.
- **`set_fact`'s `cacheable` option must be nested inside the `set_fact:`
  mapping**, alongside the variable being set — not as a sibling task-level
  keyword. Wrong: a `cacheable: true` line at the same indent as `name:`/the
  module key. Right: inside the module's own argument dict.

### Gotcha: clock skew on VMware guests

**Symptom**: `kubectl get nodes` shows `AGE` as `<invalid>`; Traefik's
`helm-install-traefik` job (or any other job needing a ServiceAccount token)
fails with `Kubernetes cluster unreachable: the server has asked for the
client to provide credentials`, and this failure repeats forever
(`CrashLoopBackOff`) even though the API server itself is healthy.

**Cause**: bearer/JWT token validation fails under clock skew between nodes.
In the reference environment, `ntpd` had silently crashed on 2 of 3 nodes
(stale PID file after a crash) and VMware Tools time sync was disabled
everywhere — the two affected nodes drifted almost 2 hours ahead of the
third. That's far too large for `ntpd`'s normal gradual-slew correction to
fix in any reasonable time, and this particular `openntpd` build had no
`libtls`, so its usual big-jump "step" correction (`-s`, or newer
constraint-based stepping) couldn't run either.

**Fix**:
1. Confirm the actual authoritative time (e.g. `curl -sI https://example.com
   | grep -i ^date:` from a node with internet access) and compare against
   `date -u` on each node.
2. Enable VMware Tools time sync everywhere (`vmware-toolbox-cmd timesync
   enable`) and **disable/stop any guest-side NTP daemon** — running both
   simultaneously causes them to fight each other. `rc-service ntpd stop &&
   rc-update del ntpd default` on Alpine/OpenRC.
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
time** — which happens if that field got written while a node's clock was
still skewed (see above). Since no valid session token can ever have an
"issued at" time later than a future `passwordMtime`, login becomes
permanently impossible until real time catches up or the field is fixed
directly.

**Fix** (once clocks are correct):
```bash
kubectl patch secret argocd-secret -n argocd --type=json \
  -p='[{"op":"remove","path":"/data/admin.passwordMtime"}]'
kubectl rollout restart deployment argocd-server -n argocd
```
This doesn't change the admin password — `argocd-server` regenerates
`passwordMtime` correctly (matching real current time) on next reconcile.

### Gotcha: `kubeadm join` reports success but the node never appears in `kubectl get nodes`

Not directly relevant if you're following this guide (which uses k3s, not
kubeadm), but worth knowing if you're comparing against an earlier kubeadm-based
attempt: `kubeadm join` only waits for the TLS bootstrap handshake to
complete — it does **not** guarantee kubelet stays running afterward. On
Alpine (or any non-systemd OS), the near-universal cause is kubelet and
containerd both defaulting to the `systemd` cgroup driver, which doesn't
exist without systemd (`Failed to create cgroup ... systemd not running on
this host`). Fix: set `SystemdCgroup = false` in `/etc/containerd/config.toml`
and `cgroupDriver: cgroupfs` in `/var/lib/kubelet/config.yaml`, then restart
both services. (This is exactly why the current setup uses k3s instead —
it doesn't have this dependency at all.)

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
that means `gami-migrate` and the CNPG `Cluster` never even get created).

Cause: ArgoCD's built-in health check for `Ingress` expects
`.status.loadBalancer.ingress` to be populated — the IP/hostname a cloud
LoadBalancer would assign. Traefik running in host-network mode (this
repo's k3s setup, `servicelb` disabled — see
`ansible/roles/k3s-server/defaults/main.yml`) never populates that field
for any Ingress, so ArgoCD considers every Ingress here permanently
unhealthy. This isn't a local-only quirk — it would happen in real
production with this same Traefik configuration too.

Fix: add a `resource.customizations.health.networking.k8s.io_Ingress` Lua
override to `argocd-cm` that treats an Ingress as healthy once it exists,
without checking `loadBalancer` status. This repo's `argocd` Ansible role
does this automatically (`files/ingress-health-check.lua` +
the "Patch argocd-cm with the Ingress health check override" task) — if
you're seeing this on a cluster bootstrapped before that task existed,
re-run `site.yml`/`alpine-local.yml`, or apply the patch by hand:
```bash
kubectl patch configmap argocd-cm -n argocd --type merge \
  --patch-file ansible/roles/argocd/files/ingress-health-check.lua
# (wrap the file's content under the right YAML key first — see the Ansible
# task for the exact patch shape; a raw Lua file isn't a valid patch on its own)
```

### Gotcha: cert-manager can't issue real certs on a local/private network

If your Ingress hostnames (`dev.authenticmemory.org` etc.) don't have real
DNS pointing at your local VMs, cert-manager's Let's Encrypt HTTP-01
challenge can never complete — the `cm-acme-http-solver` pods run forever,
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
kubectl annotate ingress gami-webapp -n <namespace> \
  cert-manager.io/cluster-issuer=selfsigned-local-test --overwrite
kubectl delete certificate gami-webapp-tls -n <namespace>
kubectl delete secret gami-webapp-tls -n <namespace>
```
This is a live, out-of-band patch for local testing only — don't commit it
to the real overlays. ArgoCD's `selfHeal: true` will revert the annotation
back to the committed `letsencrypt-staging`/`letsencrypt-production` value
on its next sync; that's expected and fine once the Ingress health check
fix above means it no longer blocks anything either way.

### Gotcha: Longhorn replica scheduling fails even after fixing the percentage threshold

Two distinct Longhorn scheduling failures look similar but need different
fixes — check `kubectl describe volumes.longhorn.io <name> -n longhorn-system`'s
`Scheduled` condition message to tell them apart:
- `"disks are unavailable"` / a disk's `Schedulable` condition is `False`
  with a `DiskPressure` reason — the node is above Longhorn's
  `storage-minimal-available-percentage` threshold (25% free by default).
  Fix: lower the setting (see `cluster-operators/longhorn/settings.yaml`).
- `"insufficient storage"` — the node has enough free *percentage* now, but
  not enough raw space for this specific PVC's requested size. Lowering the
  percentage threshold further won't fix this; the actual fix is requesting
  less storage (see `overlays/dev/postgres-cluster.yaml`'s `size:`) or
  giving the node more real disk.

Either way, after fixing the underlying cause you may need to delete the
CNPG `Cluster` (and its PVC, if orphaned: `kubectl delete pvc <name> -n
<namespace>`) rather than just the stuck pod — CNPG can get its own state
tracking wedged after a storage-related failure
(`STATUS: Cluster is unrecoverable and needs manual intervention`), and
recreating the whole `Cluster` object is more reliable than trying to
un-wedge it in place.

---

## Verifying the cluster

```bash
# Point kubectl at the new cluster (k3s writes its own kubeconfig):
ssh <any-node> 'cat /etc/rancher/k3s/k3s.yaml' > /tmp/k3s.yaml
sed -i "s/127.0.0.1/<that-node's-real-IP>/" /tmp/k3s.yaml
export KUBECONFIG=/tmp/k3s.yaml

kubectl get nodes -o wide          # all nodes should show STATUS Ready
kubectl get pods -A                # nothing should be stuck outside Running/Completed
kubectl get pods -n argocd         # full argocd-* stack should be Running
```

### Accessing the ArgoCD UI

The `argocd` Ansible role exposes ArgoCD through Traefik on a dedicated
NodePort (`30443` by default — see `ansible/roles/argocd/defaults/main.yml`'s
`argocd_ingress_port` and `files/traefik-argocd-entrypoint.yaml`'s pinned
`nodePort`), reachable on **any** node's IP:

```
https://<any-node-ip>:30443/
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

The `argocd` role already applies this repo's `argocd/*.yaml` Application
manifests, which point at `overlays/{dev,staging,production}` in **this
repo's real GitHub remote** — not useful for a local test cluster unless you
actually want it tracking the real repo.

For genuinely local app testing, either:
- Point a test `Application` at your local repo checkout / a fork, with your
  own hostnames, instead of using the committed `argocd/app-*.yaml` files
  as-is; or
- Skip ArgoCD for this and `kubectl apply -k overlays/dev` (or `staging`/
  `production`) directly against your local cluster to render and apply the
  Kustomize output once, without GitOps auto-sync.

Either way, remember the app itself needs:
- `ghcr-pull-secret` created manually (see
  `base/README-image-pull-secret.md`) — nothing pulls without it.
- **cert-manager, the CloudNativePG operator, Longhorn, and Sealed
  Secrets** — if `argocd/`'s manifests were applied (either via the
  `argocd` role or by hand), these install themselves automatically
  through `argocd/app-cluster-operators.yaml` (see [README.md](README.md)'s
  `cluster-operators/` section) — no separate step needed. If you skipped
  ArgoCD entirely and only ran `kubectl apply -k overlays/...` directly,
  you'll need to apply `cluster-operators/cert-manager`,
  `cluster-operators/cnpg`, `cluster-operators/longhorn`, and
  `cluster-operators/sealed-secrets` yourself the same way (`kubectl apply
  -k cluster-operators/cnpg --server-side` — CNPG's and Longhorn's CRDs are
  too large for client-side apply, see those Kustomizations' own comments).
- **Longhorn also needs `open-iscsi` + a running `iscsid` service on every
  node** — a real host-level dependency no manifest can satisfy. On a local
  VM this means installing it yourself to match `ansible/roles/node-baseline/tasks/main.yml`
  (`apt install open-iscsi && systemctl enable --now iscsid` on
  Debian/Ubuntu; adjust for other distros). Without this, Longhorn's
  manifest applies cleanly but PVCs sit unbound forever.
- **The CNPG Barman Cloud plugin** — only relevant if testing production's
  S3 backup locally; also GitOps-managed (`cluster-operators/cnpg-barman-plugin/`),
  applied automatically alongside cert-manager/CNPG. See
  `overlays/production/README-backup.md`.
- **The Sealed Secrets controller** — also GitOps-managed now
  (`cluster-operators/sealed-secrets/`), applied automatically alongside
  the others. It lands in `kube-system`, not its own namespace — the
  upstream manifest hardcodes that. Regardless of whether it's automatic
  or applied by hand, real secrets still need to be sealed via the
  bootstrap runbook described in each environment's own README (dev/staging/
  production) — `overlays/*/sealed-secrets/` are empty `resources: []` until
  you do this.

For a local smoke test, it's usually far simpler to run the app via its own
`docker-compose.yml` (in the `gami-app` repo) than to stand up the full
CNPG/Longhorn/SealedSecrets chain locally — this repo's local path is mainly
useful for testing **infrastructure** changes (Ansible roles, Kustomize
overlays, ArgoCD wiring), not for day-to-day app development.

---

## Tearing down / starting over

```bash
# On each node:
k3s-uninstall.sh          # or k3s-agent-uninstall.sh if it was ever an agent
```

If you were testing an earlier kubeadm-based setup and are migrating to k3s
(as this guide's reference environment did), reset that first:

```bash
kubeadm reset -f
rm -rf /etc/cni/net.d /opt/cni/bin/*
rc-service containerd stop   # or systemctl stop containerd
```

Then re-run the playbook from [Path B, step 4](#4-use-or-copy-the-local-playbook).
