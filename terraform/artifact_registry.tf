# Create the Artifact Registry repository (waits for API to be enabled)
resource "google_artifact_registry_repository" "dataflow_images" {
  provider = google
  location = var.region
  repository_id = "dataflow-images"
  description  = "Docker images for Apache Beam Dataflow jobs"
  format       = "DOCKER"

  docker_config {
    immutable_tags = false
  }

  depends_on = [google_project_service.required_services]
}

# Grant Dataflow service account permission to pull images
resource "google_artifact_registry_repository_iam_member" "dataflow_pull" {
  project    = var.project_id
  location   = var.region
  repository = google_artifact_registry_repository.dataflow_images.name
  role       = "roles/artifactregistry.reader"
  member     = google_service_account.dataflow_service_account.member
}

# Grant admin (user or CI) permission to push images
resource "google_artifact_registry_repository_iam_member" "admin_writer" {
  project    = var.project_id
  location   = var.region
  repository = google_artifact_registry_repository.dataflow_images.name
  role       = "roles/artifactregistry.writer"
  member     = var.admin_user_member
}
