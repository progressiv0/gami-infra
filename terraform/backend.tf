# State lives on Hetzner Object Storage (S3-compatible), not a local file —
# so `terraform apply` from a GitHub Actions workflow_dispatch runner (a
# fresh checkout every time) still sees the real state.
#
# The bucket ("gami-tfstate") must be created once, out of band, before the
# first `terraform init` — Terraform won't create its own state bucket.
#
# Credentials (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY, actually Hetzner
# Object Storage access keys) are passed as env vars at init/apply time —
# never committed here.
terraform {
  backend "s3" {
    bucket                      = "gami-backup"
    key                         = "infra/terraform.tfstate"
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
