# NOTE: this HCL has been written carefully but NOT run through
# `terraform validate`/`terraform plan` — there's no terraform binary in the
# environment this was authored in. Review it like a first-pass PR before
# ever pointing it at real infrastructure.
# The backend "s3" block lives in backend.tf, not here — Terraform only
# allows exactly one `backend` block across the whole configuration, and
# splitting it across two files would be a duplicate-backend error.
terraform {
  required_version = ">= 1.7"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.45"
    }
  }
}

provider "hcloud" {
  token = var.hcloud_token
}
