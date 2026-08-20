# Troubleshooting

Real failures hit while running this stack, with the symptom you'd actually
see and the fix. Skim the headings — most of these look like something else
at first, which is the whole reason they're written down.

---

## Ansible / control machine

### `Ansible could not initialize the preferred locale: unsupported locale setting`

Your shell exports locale variables the machine running Ansible can't
resolve — common when a German desktop exports `LC_NUMERIC=de_DE.UTF-8` etc.
into a container that only has `C`, `C.utf8`, `en_US.utf8` generated.
Ansible's `setlocale(LC_ALL, '')` at startup then fails outright.

```bash
LC_ALL=en_US.UTF-8 ansible-playbook -i inventory/production.yml playbooks/site.yml
```

Permanent fix — generate the missing locale where Ansible runs (Debian):

```bash
sudo sh -c 'apt-get install -y locales && \
  sed -i "s/^# *de_DE.UTF-8/de_DE.UTF-8/" /etc/locale.gen && locale-gen'
```

### `Task failed: No closing quotation`

You exported `.env` with `export $(...)`. Unquoted command substitution
splits on whitespace, so this line:

```bash
ANSIBLE_SSH_ARGS='-o ControlMaster=no'
```

becomes two words, and `ANSIBLE_SSH_ARGS` ends up as the literal three
characters `'-o` — an unterminated quote. Ansible shlex-splits `ssh_args`
while building the SSH command, which is the first thing Gathering Facts
does.

Always use the form the shell parses as shell:

```bash
set -a; source .env; set +a
```

`set -a` auto-exports every subsequent assignment; `set +a` turns it back
off. Note it **cannot unset** a variable that's already exported — if you
blank a value in `.env` and re-source, the old value is still live. `unset
VAR` explicitly, or open a fresh shell.

### `Failed to connect to the host via ssh: hostname contains invalid characters`

`GAMI_STAGING_IP` / `GAMI_PROD_IP` aren't set.
[`inventory/production.yml`](../ansible/inventory/production.yml) builds
`ansible_host` from `lookup('env', ...)`, which returns an empty string for
an unset variable rather than failing — so SSH gets `""`. Both hosts fail
identically and instantly.

Environment variables don't cross a `distrobox-enter` / container boundary
unless they were exported before you entered.

### A task silently does nothing

Several roles guard on a credential being present —
`repo-credentials.yml` and `image_pull_secret` both skip themselves when
their token is empty. A run that forgot to source `.env` looks clean and
changes nothing. Check the `skipping:` lines before assuming success.

---

## kubectl guards in Ansible

### `error: failed to create X: ... already exists`

A task meant to be idempotent isn't. The cause is the sentinel string:
`kubectl create namespace` surfaces the raw server error, which contains the
API reason —

```
Error from server (AlreadyExists): namespaces "argocd" already exists
```

— but `kubectl create serviceaccount` / `clusterrolebinding` go through a
client-side helper that rewrites the message and **drops** the reason:

```
error: failed to create serviceaccount: serviceaccounts "argocd-manager" already exists
```

So a guard matching `AlreadyExists` works for namespaces and fails for
everything else. Every guard in this repo matches the lowercase
`already exists`, which appears in both forms.

---

## ArgoCD

### `revision main must be resolved` / `authentication required: Invalid username or token`

ArgoCD's repo-server can't clone the repo, so `main` never resolves to a
SHA. Check the repository credential Secret:

```bash
sudo k3s kubectl -n argocd get secrets -l argocd.argoproj.io/secret-type=repository
```

Two distinct causes:

- **The token is stale or revoked.** Update `GAMI_INFRA_REPO_TOKEN` in
  `.env` and re-run `--tags argocd`.
- **The repo is public and the credential is wrong.** ArgoCD matches a
  credential to a repo by URL prefix and *uses* it once matched — it does
  not fall back to anonymous access. A dead token turns a working anonymous
  clone into an auth failure. Delete the Secret:
  `sudo k3s kubectl -n argocd delete secret gami-infra-repo`.

Either way, clear the cached failure afterwards:

```bash
sudo k3s kubectl -n argocd rollout restart deploy/argocd-repo-server
```

then **Hard Refresh** (not just Sync) in the UI.

### Edits to `argocd/*.yaml` don't take effect

The top-level Application objects are **not** GitOps-managed. They're
applied once by Ansible ([`roles/argocd/tasks/main.yml`](../ansible/roles/argocd/tasks/main.yml)
for staging's, `register-remote-cluster.yml` for production's). Nothing
watches the `argocd/` directory, so editing a file there and pushing changes
nothing on the cluster — the live object keeps whatever it had.

```bash
ansible-playbook -i inventory/production.yml playbooks/site.yml --tags argocd        # staging's
ansible-playbook -i inventory/production.yml playbooks/site.yml --tags register-prod # production's
```

This is the single most confusing thing in the repo: everything under
`overlays/` and `cluster-operators/apps-*/` syncs automatically, but the
files in `argocd/` need Ansible.

### `The Kubernetes API could not find argoproj.io/Application ... Make sure the "Application" CRD is installed on the destination cluster`

An App-of-Apps parent has `destination` pointing at the **remote** cluster.
`Application` is an ArgoCD CRD that only exists where ArgoCD is installed —
staging. Prod's API server has no such kind.

The parent's destination must be local
(`server: https://kubernetes.default.svc`), even when everything it deploys
ends up on prod. The children carry their own `destination.name: prod` and
sync themselves there once created.

### Sync errors that keep moving to a different resource

Two `Application` objects with the same name in the same namespace, each
`selfHeal`-ing its own `spec` over the other's. Because ArgoCD's Application
objects all live in the `argocd` namespace **on the cluster running ArgoCD**
— regardless of where they deploy to — a staging child and a production
child with the same name collide.

That's why production's children carry a `-production` suffix
([`cluster-operators/apps-production/`](../cluster-operators/apps-production/)).
Check for duplicates:

```bash
sudo k3s kubectl -n argocd get applications
```

### `failed to discover server resources for group version ...: the server could not find the requested resource`

An Application needs a CRD that isn't installed on its destination *yet* —
usually a dependent Application racing ahead of the operator that provides
its CRDs. Sync-wave only orders resources **within** one Application or one
App-of-Apps' children; independent sibling Applications aren't ordered
against each other.

Confirm the operators are Healthy, then **Hard Refresh** the dependent
Application to force fresh API discovery (ArgoCD caches the resource list
per cluster).

### `Job.batch "gami-migrate" is invalid: ... field is immutable`

Jobs are immutable, so re-applying a changed one fails. The migrate Job
needs **both** sync options, and they are not interchangeable:

- `Replace=true` → `kubectl replace`, which still fails on immutable fields
- `Force=true` → adds `--force`, making it `replace --force` = delete + recreate

[`base/gami-migrate-job.yaml`](../base/gami-migrate-job.yaml) sets
`Replace=true,Force=true`. To unblock an existing stuck Job:

```bash
sudo k3s kubectl -n gami-staging delete job gami-migrate
```

### ArgoCD sync stuck on "waiting for healthy state of ... Ingress"

ArgoCD's built-in Ingress health check expects `.status.loadBalancer.ingress`
to be populated. Traefik in host-network mode (this repo's setup, `servicelb`
disabled) never sets it, so every Ingress looks permanently unhealthy and
blocks every later sync-wave.

The `argocd` role patches `argocd-cm` with a Lua override
([`files/ingress-health-check.lua`](../ansible/roles/argocd/files/ingress-health-check.lua))
automatically. If you're on a cluster bootstrapped before that existed,
re-run the role.

### A PVC sits at "waiting for first consumer to be created before binding"

Normal for `local-path` (`volumeBindingMode: WaitForFirstConsumer`) — the
PVC stays Pending until a pod that mounts it is scheduled. You never
pre-create the directory; the provisioner does it.

It becomes a **deadlock** if the PVC is in an earlier sync-wave than its only
consumer: ArgoCD waits for the whole wave to be Healthy, a Pending PVC reads
as Progressing, so the wave never finishes and the consumer is never created.
Put a PVC in the same wave as the workload that mounts it — see
[`overlays/staging/gpr-store-pvc.yaml`](../overlays/staging/gpr-store-pvc.yaml)
and `postgres.yaml`, which both do this.

### Stale rendered manifests

ArgoCD caches rendered manifests in Redis, keyed independently of the
repo-server process — restarting `argocd-repo-server` does **not** reliably
bust it. Before concluding an annotation "isn't honored":

```bash
sudo k3s kubectl exec -n argocd <redis-pod> -- \
  redis-cli -a <password-from-argocd-redis-secret> FLUSHALL
```

---

## Cluster / networking

### Every Service name returns NXDOMAIN

CoreDNS is serving from a stale view of the cluster. Symptom: a Service that
demonstrably exists (`kubectl get svc` shows a ClusterIP) doesn't resolve
from any pod, and things that depend on Service DNS fail with confusing
downstream errors.

```bash
sudo k3s kubectl -n cnpg-system run dns-test --image=busybox:1.36 --restart=Never --command -- \
  sh -c 'nslookup barman-cloud.cnpg-system.svc.cluster.local'
sudo k3s kubectl -n cnpg-system logs dns-test
```

Fix:

```bash
sudo k3s kubectl -n kube-system rollout restart deployment coredns
```

**Known trigger**: restarting k3s on a node (e.g. to add `--tls-san`, below)
restarts the embedded API server with a new serving certificate. CoreDNS's
long-lived watch against that API server can survive the disruption in a
wedged state rather than reconnecting cleanly, silently freezing its picture
of the cluster from that moment. If you restart k3s, restart CoreDNS too.

### `x509: certificate is valid for ..., not 10.10.0.3`

k3s bakes its API server certificate's SAN list at install time. The
`gami-argocd-link` private network was created *after* k3s was installed, so
prod's certificate doesn't cover its private address — and staging's ArgoCD
fails TLS verification connecting to it.

Fix on the **prod** node (that's whose certificate is being validated):

```bash
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_EXEC="server --cluster-init --disable=servicelb --node-label env=prod --tls-san=10.10.0.3" \
  sh -
```

Re-running the install script against an existing install doesn't reinstall
or touch etcd data — it rewrites the systemd unit's `ExecStart` and restarts
k3s, which regenerates the certificate. Verify:

```bash
openssl s_client -connect 10.10.0.3:6443 -showcerts </dev/null 2>/dev/null | \
  openssl x509 -noout -text | grep -A3 "Subject Alternative Name"
```

Then restart CoreDNS (see above).
[`roles/k3s_server/tasks/cluster-init.yml`](../ansible/roles/k3s_server/tasks/cluster-init.yml)
adds this automatically for any host with `argocd_link_ip` set, so a
from-scratch rebuild gets it right.

### Clock skew breaks authentication cryptically

`kubectl get nodes` shows `AGE` as `<invalid>`; jobs needing a
ServiceAccount token fail with `the server has asked for the client to
provide credentials` forever, though the API server is healthy. Bearer/JWT
validation fails under skew.

Check `date -u` against a known-good source, enable your hypervisor's guest
time sync (and disable any guest-side NTP daemon running alongside it — they
fight), then restart anything stuck in `CrashLoopBackOff`.

### ArgoCD login bounces back to the login screen

`argocd-server` logs show `invalid session: account password has changed
since token issued` right after a successful login. `argocd-secret`'s
`admin.passwordMtime` holds a timestamp in the future — written while the
clock was skewed. No token can ever have been issued after a future
timestamp, so login is permanently impossible.

```bash
sudo k3s kubectl patch secret argocd-secret -n argocd --type=json \
  -p='[{"op":"remove","path":"/data/admin.passwordMtime"}]'
sudo k3s kubectl rollout restart deployment argocd-server -n argocd
```

The password itself doesn't change; the field is regenerated correctly.

---

## CloudNativePG

### `Cluster cannot proceed to reconciliation due to an error while interacting with plugins`

Full reason, from `.status.phaseReason`:

```
Error while discovering plugins: while getting plugin connection:
while querying plugin identity: rpc error: code = Unavailable
desc = name resolver error: produced zero addresses
```

"Produced zero addresses" is a **DNS** failure — the operator never got as
far as a TCP connection. If the plugin's Service exists and its pod is
Running, this is the stale-CoreDNS problem above, not a plugin problem.

Check in this order, cheapest first:

```bash
# 1. Does the plugin's Service exist, with the right labels?
sudo k3s kubectl -n cnpg-system get svc barman-cloud \
  -o jsonpath='labels: {.metadata.labels}{"\n"}annotations: {.metadata.annotations}{"\n"}'
#    needs label cnpg.io/pluginName and annotation cnpg.io/pluginPort

# 2. Does DNS resolve it, from a plain throwaway pod?
sudo k3s kubectl -n cnpg-system run dns-test --image=busybox:1.36 --restart=Never --command -- \
  sh -c 'nslookup barman-cloud.cnpg-system.svc.cluster.local'
sudo k3s kubectl -n cnpg-system logs dns-test

# 3. Is the plugin actually serving?
sudo k3s kubectl -n cnpg-system logs -l app=barman-cloud --tail=50
```

Standalone plugins (a separate Deployment, which `barman-cloud` is) are
discovered **dynamically** by watching Services — restarting the operator is
not the fix, despite what the sidecar-plugin documentation implies.

### `error setting app health: ... attempt to index a non-table object(nil) with key 'phaseReason'`

ArgoCD's bundled Lua health check for the CNPG `Cluster` kind crashing on a
`.status` field that isn't populated yet. Usually transient while the
Cluster is still bootstrapping. Look at the object directly rather than
trusting ArgoCD's rendering:

```bash
sudo k3s kubectl -n gami get cluster.postgresql.cnpg.io gami-postgres \
  -o jsonpath='{.status.phase}{"\n"}'
```

If it persists once the Cluster is genuinely healthy, it's a version
mismatch between ArgoCD (installed from the unpinned `stable` manifest, see
[`roles/argocd/defaults/main.yml`](../ansible/roles/argocd/defaults/main.yml))
and the pinned CNPG version.

### Application health shows `Unknown`

Usually means ArgoCD has no health check registered for a CRD — `ObjectStore`
and `ScheduledBackup` are plugin-specific and often have none. The
Application's aggregate health is the worst of its resources, so one
uninterpretable CRD drags the whole thing to Unknown while everything works
fine. Check the real objects before investigating.

### A CNPG Cluster is wedged after a storage failure

If `initdb` hits `BackoffLimitExceeded` for a storage reason (PVC pending,
disk full), CNPG's own state tracking can stay wedged after the cause is
fixed (`Cluster is unrecoverable and needs manual intervention`). Deleting
the stuck pod or Job isn't enough — delete the whole `Cluster` object (and
its orphaned PVC) and let it rebuild.

If the operator is uninstalled, a leftover `Cluster` can't be deleted
normally — its finalizer has nothing to run:

```bash
sudo k3s kubectl -n gami-staging patch cluster.postgresql.cnpg.io gami-postgres \
  --type=merge -p '{"metadata":{"finalizers":null}}'
```

---

## Application-level

### Data disappeared after a deploy or restart

See [database.md](database.md) — the two real causes are `pg_restore
--clean` failing partway, and `drizzle-kit push` reconciling a restored
schema against the app's `schema.ts`.

Note that `kubectl rollout restart` on an ArgoCD-managed Deployment counts
as drift and triggers a full sync (which re-runs the migrate Job). Use
`kubectl delete pod -l app=gami-webapp` instead.

### Config changes don't reach running pods

`generatorOptions.disableNameSuffixHash: true` means `gami-config` keeps a
stable name, so changing its contents doesn't roll the Deployment. The
trade-off is deliberate (hash-suffixed names break `envFrom.configMapRef`),
but it means pods keep their old environment until restarted. Verify what a
pod actually has:

```bash
sudo k3s kubectl -n gami-staging exec deploy/gami-webapp -- printenv | grep -i smtp
```

### Mailpit / SMTP not receiving

`SMTP_HOST=mailpit` is correct — a Service is resolvable by bare name from
any pod in the same namespace. Check, in order: the app's logs for the real
error, whether the env vars reached the running pod (above), whether the
Service has endpoints (`kubectl -n gami-staging get endpoints mailpit` —
`<none>` means the pod isn't Ready), then TCP reachability:

```bash
sudo k3s kubectl -n gami-staging exec deploy/gami-webapp -- node -e "
const s=require('net').connect(1025,'mailpit',()=>{console.log('CONNECTED');s.end()});
s.on('error',e=>console.log('ERROR',e.code,e.message));
s.setTimeout(5000,()=>{console.log('TIMEOUT');s.destroy()});"
```

Mailpit is deliberately ClusterIP-only — it captures live magic-link sign-in
tokens. Reach its UI over an SSH tunnel:

```bash
ssh -i ~/.ssh/ops@authenticmemory.org -L 8025:127.0.0.1:8025 ops@$GAMI_STAGING_IP \
  'sudo k3s kubectl -n gami-staging port-forward svc/mailpit 8025:8025'
```

### `ImagePullBackOff`

`ghcr-pull-secret` is namespace-scoped and cluster-scoped — it must exist in
`gami-staging` on staging *and* `gami` on production. GHCR package
visibility is a separate GitHub setting from repository visibility, so a
public repo can still have private packages. See
[image-pull-secret.md](image-pull-secret.md).

### cert-manager can't issue certificates

On a local rig, the HTTP-01 challenge can never complete without real DNS
pointing at your machine — expected, and harmless once the Ingress health
check override is in place. See [install-local.md](install-local.md).

On real infrastructure, a browser cert warning means checking
`kubectl describe certificate -n <ns>` before assuming the app is broken;
Traefik falls back to a self-signed cert when issuance fails. Let's Encrypt
rate limits are **per registered domain**, so staging and production share
the `authenticmemory.org` budget.

---

## Deciding which cluster you're on

Most confusing-NotFound problems are this. Staging and production are two
completely independent clusters:

- ArgoCD operations (`kubectl get application -n argocd`) → **staging**,
  always, even for production Applications
- Production workloads (`kubectl get pods -n gami`) → **production**

There is no single `kubectl get nodes` showing both. When SSH'd into a node,
run `hostname` before trusting a command's output — two root shells look
identical.
