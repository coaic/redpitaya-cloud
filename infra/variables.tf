variable "project_id" {
  type        = string
  description = "GCP project ID"
}

variable "region" {
  type        = string
  description = "GCP region for all resources"
}

variable "environment" {
  type        = string
  description = "Environment name (dev, prod)"
}

variable "submitter_email" {
  type        = string
  description = "User email that will submit Batch jobs"
}

variable "billing_account" {
  type        = string
  description = "GCP billing account ID. Leave empty to skip budget creation."
  default     = ""
}

variable "budget_usd" {
  type        = number
  description = "Monthly budget cap in USD (only used if billing_account is set)"
  default     = 20
}

variable "artifact_retention_days" {
  type        = number
  description = "Days before artifacts are auto-deleted from GCS"
  default     = 30
}
