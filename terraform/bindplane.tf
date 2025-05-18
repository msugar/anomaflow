resource "google_compute_network" "vpc" {
  name                    = "bindplane-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  name          = "bindplane-subnet"
  ip_cidr_range = "10.10.0.0/24"
  region        = var.region
  network       = google_compute_network.vpc.id
  private_ip_google_access = true
}

resource "google_compute_router" "router" {
  name    = "bindplane-router"
  network = google_compute_network.vpc.name
  region  = var.region
}

resource "google_compute_router_nat" "nat" {
  name                               = "bindplane-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

resource "google_service_account" "bindplane_sa" {
  account_id   = "bindplane-sa"
  display_name = "BindPlane GCE Service Account"
}

resource "google_compute_instance" "bindplane_server" {
  name         = "bindplane-server"
  machine_type = "e2-small"
  zone         = var.zone

  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.name
    access_config {} # Needed for outbound Internet via NAT
  }

  service_account {
    email  = google_service_account.bindplane_sa.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    enable-oslogin = "TRUE"
  }

  tags = ["iap-ssh", "bindplane-server"]
}

resource "google_compute_instance" "bindplane_collector" {
  name         = "bindplane-collector-1"
  machine_type = "e2-micro"
  zone         = var.zone

  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.name
    access_config {} # Needed for outbound Internet via NAT
  }

  service_account {
    email  = google_service_account.bindplane_sa.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    enable-oslogin = "TRUE"
  }

  tags = ["iap-ssh", "bindplane-collector"]
}

resource "google_compute_firewall" "allow_ssh_iap" {
  name    = "allow-iap-ssh"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  direction     = "INGRESS"
  source_ranges = ["35.235.240.0/20"] # IAP IP range
  target_tags   = ["iap-ssh"]
}

resource "google_compute_firewall" "allow_bindplane_server_iap" {
  name    = "allow-iap-bindplane-server"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["3001"]
  }

  direction     = "INGRESS"
  source_ranges = ["35.235.240.0/20"] # IAP IP range
  target_tags   = ["bindplane-server"]
}

resource "google_compute_firewall" "allow_bindplane_collector_to_op" {
  name    = "allow-bindplane-collector-to-op"
  network = google_compute_network.vpc.name

  direction = "INGRESS"
  priority  = 1000

  source_tags = ["bindplane-collector"]
  target_tags = ["bindplane-server"]

  allow {
    protocol = "tcp"
    ports    = ["3001"]
  }

  description = "Allow Bindplane Collector to communicate with Bindplane OP on TCP port 3001"
}

# resource "google_storage_bucket_iam_member" "bindplane_collector_bucket_writer" {
#   bucket = google_storage_bucket.telemetry_bucket.name

#   role   = "roles/storage.objectCreator"
#   member = google_service_account.bindplane_sa.member
# }

resource "google_project_iam_member" "bindplane_collector_stream_agent" {
  project = var.project_id
  role    = "roles/stream.serviceAgent"
  member  = google_service_account.bindplane_sa.member
}