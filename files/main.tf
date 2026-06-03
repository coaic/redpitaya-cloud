# main.tf
# Persistent infra for sporadic Vivado builds on GCP, Cloud Batch flavour.
# Apply once. Per-build job submissions go via submit-build.sh.

terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

variable "project_id"       { type = string }
variable "region"           { type = string, default = "australia-southeast1" }
variable "billing_account"  { type = string, default = "" }
variable "submitter_email"  {
  type        = string
  description = "Your user email; gets jobsEditor + serviceAccountUser"
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# --- APIs ---------------------------------------------------------------

resource "google_project_service" "apis" {
  for_each = toset([
    "compute.googleapis.com",
    "storage.googleapis.com",
    "batch.googleapis.com",
    "logging.googleapis.com",
    "billingbudgets.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}

# --- Output bucket ------------------------------------------------------

resource "google_storage_bucket" "artifacts" {
  name                        = "${var.project_id}-fpga-artifacts"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true

  lifecycle_rule {
    condition { age = 30 }
    action    { type = "Delete" }
  }
}

# --- Build-VM service account ------------------------------------------

resource "google_service_account" "builder" {
  account_id   = "fpga-builder"
  display_name = "FPGA build VM (Batch agent + GCS writer)"
}

resource "google_storage_bucket_iam_member" "builder_writer" {
  bucket = google_storage_bucket.artifacts.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.builder.email}"
}

# REQUIRED for custom images: Batch agent on the VM reports back to the
# Batch control plane. Without this, jobs hang then fail with
# "no VM has agent reporting correctly within the time window".
resource "google_project_iam_member" "builder_agent" {
  project = var.project_id
  role    = "roles/batch.agentReporter"
  member  = "serviceAccount:${google_service_account.builder.email}"
}

resource "google_project_iam_member" "builder_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.builder.email}"
}

# --- Submitter (you) IAM -----------------------------------------------

resource "google_project_iam_member" "submitter_jobs_editor" {
  project = var.project_id
  role    = "roles/batch.jobsEditor"
  member  = "user:${var.submitter_email}"
}

# Required to submit a job that runs as the builder SA
resource "google_service_account_iam_member" "submitter_actas" {
  service_account_id = google_service_account.builder.name
  role               = "roles/iam.serviceAccountUser"
  member             = "user:${var.submitter_email}"
}

# --- Budget alert ------------------------------------------------------

resource "google_billing_budget" "fpga" {
  count           = var.billing_account == "" ? 0 : 1
  billing_account = var.billing_account
  display_name    = "FPGA project budget"

  budget_filter {
    projects = ["projects/${var.project_id}"]
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = "20"
    }
  }

  threshold_rules { threshold_percent = 0.5 }
  threshold_rules { threshold_percent = 0.9 }
  threshold_rules { threshold_percent = 1.0 }
}

# --- Outputs -----------------------------------------------------------

output "artifacts_bucket"       { value = google_storage_bucket.artifacts.name }
output "service_account_email"  { value = google_service_account.builder.email }
