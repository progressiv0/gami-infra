# `ghcr-pull-secret`

Every Deployment/Job in this repo references `imagePullSecrets: [{name:
ghcr-pull-secret}]`, but there's deliberately no `image-pull-secret.yaml` here
— a real `.dockerconfigjson` credential is not something to commit to git,
even encrypted-at-rest-adjacent via Sealed Secrets (it's a long-lived registry
credential, not an app secret with its own rotation story).

Create it once per cluster, directly, out of band:

```bash
kubectl create secret docker-registry ghcr-pull-secret \
  --namespace gami \
  --docker-server=ghcr.io \
  --docker-username=<github-username> \
  --docker-password=<fine-grained PAT, read:packages only> \
  --docker-email=<email>
```

This lives only on the cluster, never in `gami-infra` git — matches the plan
(`infrastructure-cicd-plan.md`, Phase 3/5).
