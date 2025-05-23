/**
 * Terraform configuration for Anomaly Detection Pipeline on GCP
 */

terraform {
  backend "gcs" {}
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# Enable required APIs
resource "google_project_service" "required_services" {
  for_each = toset([
    "dataflow.googleapis.com",
    "pubsub.googleapis.com",
    "storage.googleapis.com",
    "bigquery.googleapis.com",
    "compute.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
  ])

  project = var.project_id
  service = each.key

  disable_on_destroy = false
}

# Service account for Dataflow
resource "google_service_account" "dataflow_service_account" {
  account_id   = "anomaly-detection-sa"
  display_name = "Service Account for Anomaly Detection Pipeline"
  depends_on   = [google_project_service.required_services]
}

# Grant necessary roles to the service account
resource "google_project_iam_member" "dataflow_worker_role" {
  project = var.project_id
  role    = "roles/dataflow.worker"
  member  = google_service_account.dataflow_service_account.member
}

# Also ensure you have the Dataflow Admin role for job submission
resource "google_project_iam_member" "dataflow_admin_role" {
  project = var.project_id
  role    = "roles/dataflow.admin"
  #member  = google_service_account.dataflow_service_account.member
  member = var.admin_user_member
}

resource "google_project_iam_member" "compute_admin_role" {
  project = var.project_id
  role    = "roles/compute.admin"
  member  = google_service_account.dataflow_service_account.member
}

resource "google_project_iam_member" "storage_admin_role" {
  project = var.project_id
  role    = "roles/storage.admin"
  member  = google_service_account.dataflow_service_account.member
}

resource "google_project_iam_member" "pubsub_subscriber_role" {
  project = var.project_id
  role    = "roles/pubsub.subscriber"
  member  = google_service_account.dataflow_service_account.member
}

resource "google_project_iam_member" "bigquery_data_editor_role" {
  project = var.project_id
  role    = "roles/bigquery.dataEditor"
  member  = google_service_account.dataflow_service_account.member
}

# Create a GCS bucket for OpenTelemetry data
resource "google_storage_bucket" "telemetry_bucket" {
  name          = "${var.project_id}-telemetry"
  location      = var.region
  force_destroy = true

  uniform_bucket_level_access = true

  # Add soft delete prevention configuration
  soft_delete_policy {
    retention_duration_seconds = 0 # Disables soft delete
  }

  lifecycle_rule {
    condition {
      age = var.data_retention_days
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.required_services]
}


# Create a GCS bucket for Dataflow temp files
resource "google_storage_bucket" "dataflow_temp_bucket" {
  name          = "${var.project_id}-dataflow-temp"
  location      = var.region
  force_destroy = true

  uniform_bucket_level_access = true

  # Disable soft delete to prevent the warning
  soft_delete_policy {
    retention_duration_seconds = 0 # Disables soft delete
  }

  lifecycle_rule {
    condition {
      age = 1
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.required_services]
}

# Create notification topic for new files
resource "google_pubsub_topic" "new_telemetry_topic" {
  name       = "new-telemetry-file-notifications"
  depends_on = [google_project_service.required_services]
}

# Create subscription for the notification topic
resource "google_pubsub_subscription" "telemetry_subscription" {
  name                 = "telemetry-file-subscription"
  topic                = google_pubsub_topic.new_telemetry_topic.name
  ack_deadline_seconds = 20

  expiration_policy {
    ttl = "" # Never expire
  }

  depends_on = [google_pubsub_topic.new_telemetry_topic]
}

resource "google_pubsub_topic_iam_member" "allow_gcs_publish" {
  topic  = google_pubsub_topic.new_telemetry_topic.name
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:service-${var.project_number}@gs-project-accounts.iam.gserviceaccount.com"
}


# Enable notifications from GCS to Pub/Sub
resource "google_storage_notification" "telemetry_notification" {
  bucket         = google_storage_bucket.telemetry_bucket.name
  payload_format = "JSON_API_V1"
  topic          = google_pubsub_topic.new_telemetry_topic.id
  event_types    = ["OBJECT_FINALIZE"]

  depends_on = [
    google_pubsub_topic.new_telemetry_topic,
    google_storage_bucket.telemetry_bucket,
    google_pubsub_topic_iam_member.allow_gcs_publish
  ]
}

# Create BigQuery dataset for anomaly results
resource "google_bigquery_dataset" "anomaly_dataset" {
  dataset_id    = "anomaly_detection"
  friendly_name = "Anomaly Detection Results"
  description   = "Dataset containing detected system anomalies"
  location      = var.region

  labels = {
    environment = var.environment
  }

  depends_on = [google_project_service.required_services]
}

# Create tables for different anomaly types
resource "google_bigquery_table" "metric_anomalies_table" {
  dataset_id = google_bigquery_dataset.anomaly_dataset.dataset_id
  table_id   = "metric_anomalies"

  schema = <<EOF
[
  {
    "name": "timestamp",
    "type": "TIMESTAMP",
    "mode": "REQUIRED",
    "description": "Time when the anomaly occurred"
  },
  {
    "name": "detection_time",
    "type": "TIMESTAMP",
    "mode": "REQUIRED",
    "description": "Time when the anomaly was detected"
  },
  {
    "name": "metric_name",
    "type": "STRING",
    "mode": "REQUIRED",
    "description": "Name of the metric"
  },
  {
    "name": "resource",
    "type": "STRING",
    "mode": "REQUIRED",
    "description": "Resource where the anomaly was detected"
  },
  {
    "name": "value",
    "type": "FLOAT",
    "mode": "REQUIRED",
    "description": "Anomalous metric value"
  },
  {
    "name": "mean_value",
    "type": "FLOAT",
    "mode": "REQUIRED",
    "description": "Mean value for comparison"
  },
  {
    "name": "std_dev",
    "type": "FLOAT",
    "mode": "REQUIRED",
    "description": "Standard deviation"
  },
  {
    "name": "z_score",
    "type": "FLOAT",
    "mode": "REQUIRED",
    "description": "Z-score of the anomaly"
  },
  {
    "name": "anomaly_type",
    "type": "STRING",
    "mode": "REQUIRED",
    "description": "Type of anomaly detected"
  },
  {
    "name": "severity",
    "type": "STRING",
    "mode": "REQUIRED",
    "description": "Severity level of the anomaly"
  },
  {
    "name": "detection_id",
    "type": "STRING",
    "mode": "REQUIRED",
    "description": "Unique identifier for the detection"
  }
]
EOF

  depends_on = [google_bigquery_dataset.anomaly_dataset]
}

resource "google_bigquery_table" "log_anomalies_table" {
  dataset_id = google_bigquery_dataset.anomaly_dataset.dataset_id
  table_id   = "log_anomalies"

  schema = <<EOF
[
  {
    "name": "timestamp",
    "type": "TIMESTAMP",
    "mode": "REQUIRED", 
    "description": "Time when the anomaly occurred"
  },
  {
    "name": "resource",
    "type": "STRING",
    "mode": "REQUIRED",
    "description": "Resource where the anomaly was detected"
  },
  {
    "name": "anomaly_type",
    "type": "STRING",
    "mode": "REQUIRED",
    "description": "Type of log anomaly detected"
  },
  {
    "name": "description",
    "type": "STRING",
    "mode": "REQUIRED",
    "description": "Description of the anomaly"
  },
  {
    "name": "pattern",
    "type": "STRING",
    "mode": "NULLABLE",
    "description": "Pattern detected in logs"
  },
  {
    "name": "count",
    "type": "INTEGER",
    "mode": "NULLABLE",
    "description": "Count of pattern occurrences"
  },
  {
    "name": "severity",
    "type": "STRING",
    "mode": "REQUIRED",
    "description": "Severity level of the anomaly"
  },
  {
    "name": "detection_id",
    "type": "STRING",
    "mode": "REQUIRED",
    "description": "Unique identifier for the detection"
  }
]
EOF

  depends_on = [google_bigquery_dataset.anomaly_dataset]
}

# Create a VPC network for Dataflow
resource "google_compute_network" "dataflow_network" {
  name                    = "dataflow-network"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.required_services]
}

# Create a subnet for Dataflow workers
resource "google_compute_subnetwork" "dataflow_subnet" {
  name          = "dataflow-subnet"
  ip_cidr_range = "10.0.0.0/24"
  region        = var.region
  network       = google_compute_network.dataflow_network.id

  # This is crucial for Dataflow
  private_ip_google_access = true
}

# Firewall rule to allow Dataflow internal communication
resource "google_compute_firewall" "dataflow_internal" {
  name    = "dataflow-internal-communication"
  network = google_compute_network.dataflow_network.name

  description = "Allow internal communication between Dataflow workers"

  allow {
    protocol = "tcp"
    ports    = ["12345-12346"]
  }

  # Either use source_tags or source_ranges, not both
  source_tags = ["dataflow"]
  target_tags = ["dataflow"]

  depends_on = [google_compute_network.dataflow_network]
}

# Optional: Allow SSH for debugging (recommended)
resource "google_compute_firewall" "dataflow_ssh" {
  name    = "dataflow-ssh"
  network = google_compute_network.dataflow_network.name

  description = "Allow SSH to Dataflow workers for debugging"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_tags = ["dataflow"]
  target_tags = ["dataflow"]

  depends_on = [google_compute_network.dataflow_network]
}

# Allow health checks and internal communication
resource "google_compute_firewall" "dataflow_health_checks" {
  name    = "dataflow-health-checks"
  network = google_compute_network.dataflow_network.name

  description = "Allow health checks for Dataflow workers"

  allow {
    protocol = "tcp"
    ports    = ["8080", "8443"]
  }

  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = ["dataflow"]

  depends_on = [google_compute_network.dataflow_network]
}

# Create a Dataflow job template
# Note: The actual job will be launched by the Python script
resource "google_dataflow_job" "anomaly_detection_job" {
  count                 = var.deploy_dataflow_job ? 1 : 0
  name                  = "anomaly-detection-pipeline"
  template_gcs_path     = "gs://dataflow-templates/latest/PubSub_to_BigQuery"
  temp_gcs_location     = "${google_storage_bucket.dataflow_temp_bucket.url}/temp"
  service_account_email = google_service_account.dataflow_service_account.email
  network               = google_compute_network.dataflow_network.name
  subnetwork            = google_compute_subnetwork.dataflow_subnet.self_link
  region                = var.region

  parameters = {
    inputTopic      = google_pubsub_topic.new_telemetry_topic.id
    outputTableSpec = "${var.project_id}:${google_bigquery_dataset.anomaly_dataset.dataset_id}.${google_bigquery_table.metric_anomalies_table.table_id}"
  }

  depends_on = [
    google_pubsub_topic.new_telemetry_topic,
    google_bigquery_table.metric_anomalies_table,
    google_service_account.dataflow_service_account,
    google_project_iam_member.dataflow_worker_role,
    google_project_iam_member.storage_admin_role,
    google_project_iam_member.pubsub_subscriber_role,
    google_project_iam_member.bigquery_data_editor_role
  ]
}

# Output important resource identifiers
output "project_id" {
  value = var.project_id
}

output "region" {
  value = var.region
}

output "zone" {
  value = var.zone
}

output "telemetry_bucket_name" {
  value       = google_storage_bucket.telemetry_bucket.name
  description = "The name of the GCS bucket for telemetry data"
}

output "pubsub_topic_name" {
  value       = google_pubsub_topic.new_telemetry_topic.name
  description = "The name of the Pub/Sub topic for file notifications"
}

output "bigquery_dataset_id" {
  value       = google_bigquery_dataset.anomaly_dataset.dataset_id
  description = "The ID of the BigQuery dataset for anomaly results"
}

output "dataflow_service_account_email" {
  value       = google_service_account.dataflow_service_account.email
  description = "The email of the service account for Dataflow"
}

output "dataflow_temp_bucket" {
  value       = google_storage_bucket.dataflow_temp_bucket.name
  description = "The name of the GCS bucket for Dataflow temp files"
}

output "dataflow_network" {
  value       = google_compute_network.dataflow_network.name
  description = "The name of the VPC network for Dataflow"
}

output "dataflow_subnet" {
  value       = google_compute_subnetwork.dataflow_subnet.name
  description = "The name of the subnetwork for Dataflow"
}
