/**
 * Variables for the Anomaly Detection Pipeline on GCP
 */

variable "project_id" {
  description = "The GCP project ID"
  type        = string
}

variable "project_number" {
  description = "The numeric GCP project number (used for IAM bindings like GCS -> Pub/Sub)."
  type        = string
}

variable "region" {
  description = "The GCP region for resources"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "The GCP zone for resources"
  type        = string
  default     = "us-central1-b"
}

variable "tf_state_bucket_name" {
  description = "Name of the GCS bucket to store the Terraform state"
  type        = string
}

variable "environment" {
  description = "Environment label for resources (dev, test, prod)"
  type        = string
  default     = "dev"
}

variable "data_retention_days" {
  description = "Number of days to retain telemetry data"
  type        = number
  default     = 30
}

variable "deploy_dataflow_job" {
  description = "Whether to deploy the Dataflow job via Terraform"
  type        = bool
  default     = false
}

variable "machine_type" {
  description = "Machine type for Dataflow workers"
  type        = string
  default     = "n1-standard-2"
}

variable "max_workers" {
  description = "Maximum number of Dataflow workers"
  type        = number
  default     = 5
}

variable "min_workers" {
  description = "Minimum number of Dataflow workers (for streaming jobs)"
  type        = number
  default     = 1
}

variable "worker_disk_type" {
  description = "Disk type for Dataflow workers"
  type        = string
  default     = "pd-standard"
}

variable "worker_disk_size_gb" {
  description = "Disk size for Dataflow workers in GB"
  type        = number
  default     = 50
}