provider "google" {
  project = var.project
  region  = var.region
}

resource "google_storage_bucket" "terraform_state" {
  name     = var.tf_state_bucket_name
  location = var.region
  force_destroy = true

  versioning {
    enabled = true
  }

  uniform_bucket_level_access = true
}
