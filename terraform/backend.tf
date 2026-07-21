# State lives on Hetzner Object Storage (S3-compatible), not a local file —
# so `terraform apply` from a GitHub Actions workflow_dispatch runner (a
# fresh checkout every time) still sees the real state.
#
# The bucket ("gami-prod-backup") must be created once, out of band, before
# the first `terraform init` — Terraform won't create its own state bucket.
# Shared with production's CNPG S3 backups
# (overlays/production/database/postgres-cluster.yaml's ObjectStore), under
# its own key prefix so state and backup data stay clearly separated.
#
# Credentials (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY, actually Hetzner
# Object Storage access keys) are passed as env vars at init/apply time —
# never committed here.
#
# NOTE: this bucket was renamed from "gami-backup" (key was
# "infra/terraform.tfstate") to "gami-prod-backup" (key
# "tf-infrastructure/terraform.tfstate"). Changing a Terraform S3 backend's
# bucket/key does NOT move the underlying state object — that needs
# `terraform init -migrate-state` (or a manual object copy) run by hand
# against the real bucket, ideally after backing up the current state
# object first. Do this before running `terraform` again with this config.
terraform {
  backend "s3" {
    bucket                      = "gami-prod-backup"
    key                         = "tf-infrastructure/terraform.tfstate"
    region                      = "Falkenstein"
    endpoints                   = { s3 = "https://fsn1.your-objectstorage.com" }
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    # Both needed for S3-compatible (non-AWS) endpoints like Hetzner's —
    # virtual-hosted-style bucket addressing and AWS's newer default
    # checksum algorithms commonly don't work against them.
    use_path_style   = true
    skip_s3_checksum = true
  }
}
