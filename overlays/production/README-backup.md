# Production Postgres backups

Only production backs up to S3 — dev and staging don't (see `README.md`'s
"Node topology" section for why: they're explicitly not meant to be highly
reliable, so there's nothing to protect beyond redeploying).

## What's already automatic

`postgres-cluster.yaml` wires up:
- A nightly `ScheduledBackup` (`gami-postgres-nightly`, 02:00 daily) — the
  baseline safety net, no action needed once the cluster is bootstrapped.
- 30-day retention (`ObjectStore.spec.retentionPolicy`) — older backups are
  pruned automatically.

## One-time setup (before the first backup can run)

1. **Confirm the Barman Cloud CNPG-I plugin is installed** (separate from
   the CNPG operator itself — required since CNPG 1.26 deprecated the old
   inline `spec.backup.barmanObjectStore` field in favor of this plugin).
   This is no longer a manual step — `argocd/app-cluster-operators.yaml`
   installs it automatically (see [README.md](README.md)'s
   `cluster-operators/` section for the pinned version and why it's
   GitOps-managed instead of a one-off `kubectl apply`). Just verify it's
   actually up:
   ```bash
   kubectl get pods -n cnpg-system -l app.kubernetes.io/name=barman-cloud
   ```
   To bump its version, edit `cluster-operators/cnpg-barman-plugin/kustomization.yaml`'s
   pinned URL — check the [plugin's releases page](https://github.com/cloudnative-pg/plugin-barman-cloud/releases)
   for the current version, commit, push, and let ArgoCD sync it.

2. **Create the S3 credentials Secret** (references the same Hetzner Object
   Storage account already used for Terraform state — see
   `terraform/backend.tf` — with a separate Object Storage access key pair
   if you want backup access scoped independently from Terraform's):
   ```bash
   kubectl create secret generic gami-postgres-backup-creds \
     --namespace gami \
     --from-literal=ACCESS_KEY_ID="<Hetzner Object Storage access key>" \
     --from-literal=ACCESS_SECRET_KEY="<Hetzner Object Storage secret key>"
   ```
   Not committed to git, same reasoning as `ghcr-pull-secret`
   (`base/README-image-pull-secret.md`) — a long-lived storage credential,
   not an app secret with its own rotation story.

3. Confirm the bucket (`gami-tfstate`) actually allows the prefix
   `postgres-backups/production/` to be written — it's the same bucket as
   Terraform state, just a different key prefix, so no new bucket creation
   is needed, only confirming the credentials above have write access to it.

## Triggering an on-demand backup

Outside the nightly schedule (e.g. right before a risky migration):

```bash
kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: gami-postgres-manual-$(date +%Y%m%d-%H%M%S)
  namespace: gami
spec:
  cluster:
    name: gami-postgres
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF
```

Check status:
```bash
kubectl get backup -n gami
kubectl describe backup <name> -n gami
```

This is also the command the design plan's Phase 6 `/admin/ops` page (not
yet implemented) is meant to trigger on your behalf via a scoped in-cluster
ServiceAccount — see `.claude/plans/infrastructure-cicd-plan.md`, Phase 6.

## Verifying backups actually work

Don't trust a green `ScheduledBackup` status alone — periodically confirm a
**restore** actually works, e.g. in a scratch namespace:
```bash
kubectl get backup -n gami   # find a completed backup's name
```
Then bootstrap a throwaway `Cluster` with `.spec.bootstrap.recovery` pointing
at that backup, confirm the data is actually there and queryable, and delete
the scratch cluster afterward. CNPG's own docs cover the exact
`bootstrap.recovery` shape for the plugin model — check the version-specific
docs for the CNPG release you're running.
