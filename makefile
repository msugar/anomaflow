# Makefile for running Anomaflow Beam pipeline

# Configuration
SHELL := /bin/bash
.DEFAULT_GOAL := help

# Paths
PYTHON_DIR := python
MAIN_SCRIPT := $(PYTHON_DIR)/anomaflow/pipeline.py
TEST_SCRIPT := $(PYTHON_DIR)/anomaflow/test_pipeline.py

# Local paths
LOCAL_INPUT_PATH := data/input
LOCAL_OUTPUT_PATH := data/output

# Terraform paths
TERRAFORM_DIR := terraform
TFVARS_FILE := $(TERRAFORM_DIR)/terraform.tfvars
TFVARS_TEMPLATE := $(TERRAFORM_DIR)/terraform.tfvars.templ
BOOTSTRAP_DIR := $(TERRAFORM_DIR)/bootstrap

# Runtime variables (loaded from Terraform outputs)
PROJECT_ID :=
REGION :=
ZONE :=
TELEMETRY_BUCKET :=
TEMP_BUCKET :=
GCS_BUCKET_INPUT :=
GCS_BUCKET_OUTPUT :=
GCS_BUCKET_TEMP :=
DATAFLOW_NETWORK :=
DATAFLOW_SUBNET :=
DATAFLOW_SERVICE_ACCOUNT_EMAIL :=

# Configuration variables (can be overridden)
WINDOW_SIZE ?= 600
IMAGE_TAG ?= latest
ZONE_SUFFIX ?=

# Docker configuration (deferred expansion)
IMAGE_NAME := anomaflow
IMAGE_REPO = $(REGION)-docker.pkg.dev/$(PROJECT_ID)/dataflow-images
IMAGE_URI = $(IMAGE_REPO)/$(IMAGE_NAME):$(IMAGE_TAG)

.PHONY: help validate-env local remote dataflow dataflow-stream dataflow-test \
        build-container build-container-cloud push-container iap-tunnel tf-bootstrap tf-init \
        load-terraform-outputs cleanup check-dependencies check-docker

help: ## Show this help message
	@echo "Anomaflow Pipeline Makefile"
	@echo ""
	@echo "Usage:"
	@awk 'BEGIN {FS = ":.*##"; printf ""} /^[a-zA-Z_-]+:.*?##/ { printf "  %-20s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@echo ""
	@echo "Configuration Variables:"
	@echo "  WINDOW_SIZE     Window size in seconds (default: $(WINDOW_SIZE))"
	@echo "  IMAGE_TAG       Docker image tag (default: $(IMAGE_TAG))"
	@echo "  ZONE_SUFFIX     Zone suffix for worker placement"
	@echo ""
	@echo "Examples:"
	@echo "  make local WINDOW_SIZE=120"
	@echo "  make dataflow IMAGE_TAG=dev"
	@echo "  make build-container IMAGE_TAG=v1.2.3        # Requires Docker"
	@echo "  make build-container-cloud IMAGE_TAG=v1.2.3  # Uses Cloud Build"

check-dependencies: ## Verify required tools are installed
	@echo "Checking dependencies..."
	@command -v python3 >/dev/null || (echo "Error: python3 not found" && exit 1)
	@command -v terraform >/dev/null || (echo "Error: terraform not found" && exit 1)
	@command -v gcloud >/dev/null || (echo "Error: gcloud not found" && exit 1)
	@command -v jq >/dev/null || (echo "Error: jq not found" && exit 1)
	@echo "Core dependencies found"

check-docker: ## Check if Docker is available
	@command -v docker >/dev/null || (echo "Warning: Docker not found - use 'make build-container-cloud' instead" && exit 1)
	@echo "Docker found"

validate-env: ## Validate environment and required files
	@echo "Validating environment..."
	@[ -f "$(MAIN_SCRIPT)" ] || (echo "Error: Main script not found: $(MAIN_SCRIPT)" && exit 1)
	@[ -d "$(LOCAL_INPUT_PATH)" ] || (echo "Error: Input directory not found: $(LOCAL_INPUT_PATH)" && exit 1)
	@echo "Environment validation passed"

cleanup: ## Clean up local output directory
	@echo "Cleaning up local output directory..."
	@rm -rf $(LOCAL_OUTPUT_PATH)/*
	@echo "Cleanup completed"

# Sets variables by reading Terraform outputs and exporting them to Make
load-terraform-outputs:
	@echo "Fetching Terraform outputs..."
	@if ! terraform -chdir=terraform output -json >/dev/null 2>&1; then \
		echo "Error: Failed to read Terraform outputs. Ensure terraform is initialized and applied."; \
		exit 1; \
	fi
	$(eval TF_OUTPUTS := $(shell terraform -chdir=terraform output -json))
	$(eval PROJECT_ID := $(shell echo '$(TF_OUTPUTS)' | jq -r '.project_id.value'))
	$(eval REGION := $(shell echo '$(TF_OUTPUTS)' | jq -r '.region.value'))
	$(eval ZONE := $(shell echo '$(TF_OUTPUTS)' | jq -r '.zone.value'))
	$(eval TELEMETRY_BUCKET := $(shell echo '$(TF_OUTPUTS)' | jq -r '.telemetry_bucket_name.value'))
	$(eval TEMP_BUCKET := $(shell echo '$(TF_OUTPUTS)' | jq -r '.dataflow_temp_bucket.value'))
	$(eval GCS_BUCKET_INPUT := gs://$(TELEMETRY_BUCKET))
	$(eval GCS_BUCKET_OUTPUT := gs://$(TELEMETRY_BUCKET))
	$(eval GCS_BUCKET_TEMP := gs://$(TEMP_BUCKET))
	$(eval DATAFLOW_NETWORK := $(shell echo '$(TF_OUTPUTS)' | jq -r '.dataflow_network.value'))
	$(eval DATAFLOW_SUBNET := $(shell echo '$(TF_OUTPUTS)' | jq -r '.dataflow_subnet.value'))
	$(eval DATAFLOW_SERVICE_ACCOUNT_EMAIL := $(shell echo '$(TF_OUTPUTS)' | jq -r '.dataflow_service_account_email.value'))
	$(eval WORKER_ZONE_FLAG := --worker_zone="$(if $(ZONE_SUFFIX),$(REGION)-$(ZONE_SUFFIX),$(ZONE))")
	@echo "Terraform outputs loaded successfully"

local: validate-env cleanup ## Run pipeline locally with DirectRunner
	@echo "Running pipeline locally..."
	python3 $(MAIN_SCRIPT) \
		--runner=DirectRunner \
		--input_path="$(LOCAL_INPUT_PATH)/*.json" \
		--output_path="$(LOCAL_OUTPUT_PATH)/" \
		--window_size=$(WINDOW_SIZE)
	@echo "Local pipeline completed"

remote: load-terraform-outputs ## Run pipeline locally with remote GCS data
	@echo "Running pipeline with remote data..."
	python3 $(MAIN_SCRIPT) \
		--runner=DirectRunner \
		--input_path="$(GCS_BUCKET_INPUT)/input/year=2025/month=05/day=18/hour=04/minute=*/*.json" \
		--output_path="$(GCS_BUCKET_OUTPUT)/output/" \
		--window_size=$(WINDOW_SIZE)
	@echo "Remote pipeline completed"

dataflow: load-terraform-outputs ## Run pipeline on Google Cloud Dataflow (batch)
	@echo "Starting Dataflow batch job..."
	@echo "Image: $(IMAGE_URI)"
	python3 $(MAIN_SCRIPT) \
		--runner=DataflowRunner \
		--project="$(PROJECT_ID)" \
		--region="$(REGION)" \
		--network="$(DATAFLOW_NETWORK)" \
		--subnetwork="regions/$(REGION)/subnetworks/$(DATAFLOW_SUBNET)" \
		--service_account_email="$(DATAFLOW_SERVICE_ACCOUNT_EMAIL)" \
		--temp_location="$(GCS_BUCKET_TEMP)/temp/" \
		--staging_location="$(GCS_BUCKET_TEMP)/staging/" \
		--sdk_container_image="$(IMAGE_URI)" \
		--input_path="$(GCS_BUCKET_INPUT)/input/year=2025/month=*/day=*/hour=*/minute=*/*.json" \
		--output_path="$(GCS_BUCKET_OUTPUT)/output/" \
		--window_size=$(WINDOW_SIZE) \
		--max_num_workers=3 \
		--num_workers=1 \
		$(WORKER_ZONE_FLAG) \
		--machine_type="e2-medium"
	@echo "Dataflow job submitted"

dataflow-stream: load-terraform-outputs ## Run streaming pipeline on Google Cloud Dataflow
	@echo "Starting Dataflow streaming job..."
	python3 $(MAIN_SCRIPT) \
		--runner=DataflowRunner \
		--project="$(PROJECT_ID)" \
		--region="$(REGION)" \
		--network="$(DATAFLOW_NETWORK)" \
		--subnetwork="regions/$(REGION)/subnetworks/$(DATAFLOW_SUBNET)" \
		--service_account_email="$(DATAFLOW_SERVICE_ACCOUNT_EMAIL)" \
		--temp_location="$(GCS_BUCKET_TEMP)/temp/" \
		--staging_location="$(GCS_BUCKET_TEMP)/staging/" \
		--sdk_container_image="$(IMAGE_URI)" \
		--input_path="$(GCS_BUCKET_INPUT)/input/year=2025/month=05/day=18/hour=*/minute=*/*.json" \
		--output_path="$(GCS_BUCKET_OUTPUT)/output/" \
		--window_size=$(WINDOW_SIZE) \
		--streaming \
		--max_num_workers=3 \
		--num_workers=1 \
		$(WORKER_ZONE_FLAG) \
		--machine_type="e2-medium"
	@echo "Dataflow streaming job submitted"

dataflow-test: load-terraform-outputs ## Run test pipeline on Google Cloud Dataflow
	@echo "Running Dataflow test..."
	python3 $(TEST_SCRIPT) \
		--runner=DataflowRunner \
		--project="$(PROJECT_ID)" \
		--region="$(REGION)" \
		--network="$(DATAFLOW_NETWORK)" \
		--subnetwork="regions/$(REGION)/subnetworks/$(DATAFLOW_SUBNET)" \
		--service_account_email="$(DATAFLOW_SERVICE_ACCOUNT_EMAIL)" \
		--temp_location="$(GCS_BUCKET_TEMP)/temp/" \
		--staging_location="$(GCS_BUCKET_TEMP)/staging/" \
		--sdk_container_image="$(IMAGE_URI)" \
		--output="$(GCS_BUCKET_OUTPUT)/test-output" \
		--max_num_workers=3 \
		--num_workers=1 \
		$(WORKER_ZONE_FLAG) \
		--machine_type="e2-medium"
	@echo "Dataflow test completed"

build-container: check-docker load-terraform-outputs ## Build Docker container image (requires Docker)
	@echo "Building Docker image: $(IMAGE_URI)"
	@[ -f "docker/Dockerfile" ] || (echo "Error: Dockerfile not found at docker/Dockerfile" && exit 1)
	docker build -f docker/Dockerfile -t $(IMAGE_URI) .
	@echo "Docker image built successfully"

build-container-cloud: load-terraform-outputs ## Build container using Google Cloud Build (no Docker required)
	@echo "Building container using Cloud Build: $(IMAGE_URI)"
	@[ -f "docker/Dockerfile" ] || (echo "Error: Dockerfile not found at docker/Dockerfile" && exit 1)
	gcloud builds submit \
		--config=cloud-build/cloudbuild.yaml \
		--substitutions=_IMAGE_URI=$(IMAGE_URI) \
		--project=$(PROJECT_ID) \
		--region=$(REGION) \
		.
	@echo "Container built and pushed successfully using Cloud Build"

push-container: build-container ## Build and push Docker container to Artifact Registry (requires Docker)
	@echo "Pushing Docker image to Artifact Registry..."
	@gcloud auth configure-docker $(REGION)-docker.pkg.dev --quiet
	docker push $(IMAGE_URI)
	@echo "Image pushed successfully: $(IMAGE_URI)"

iap-tunnel: load-terraform-outputs ## Create IAP tunnel to bindplane-server
	@echo "Creating IAP tunnel to bindplane-server on localhost:3001..."
	@echo "Project: $(PROJECT_ID), Zone: $(ZONE)"
	@echo "Press Ctrl+C to stop the tunnel"
	gcloud compute start-iap-tunnel bindplane-server 3001 \
		--local-host-port=localhost:3001 \
		--zone="$(ZONE)" \
		--project="$(PROJECT_ID)"

tf-bootstrap: check-dependencies ## Bootstrap Terraform state bucket
	@echo "Bootstrapping Terraform state bucket..."
	@if [ ! -f "$(TFVARS_FILE)" ]; then \
		echo "Missing file: $(TFVARS_FILE)"; \
		echo "Please create it by copying the template and filling in values:"; \
		echo ""; \
		echo "    cp $(TFVARS_TEMPLATE) $(TFVARS_FILE)"; \
		echo "    # Then edit $(TFVARS_FILE) with your GCP project info."; \
		echo ""; \
		exit 1; \
	fi
	$(eval PROJECT := $(shell grep '^project' "$(TFVARS_FILE)" | awk -F '"' '{print $$2}'))
	$(eval REGION := $(shell grep '^region' "$(TFVARS_FILE)" | awk -F '"' '{print $$2}'))
	$(eval TF_STATE_BUCKET_NAME := $(shell grep '^tf_state_bucket_name' "$(TFVARS_FILE)" | awk -F '"' '{print $$2}'))
	@if [ -z "$(PROJECT)" ] || [ -z "$(REGION)" ] || [ -z "$(TF_STATE_BUCKET_NAME)" ]; then \
		echo "One or more required variables are missing or malformed in $(TFVARS_FILE)."; \
		echo "Make sure it includes lines like:"; \
		echo '    project               = "your-gcp-project-id"'; \
		echo '    region                = "your-region"'; \
		echo '    tf_state_bucket_name  = "your-terraform-state-bucket"'; \
		echo ""; \
		exit 1; \
	fi
	@echo "Project: $(PROJECT)"
	@echo "Region: $(REGION)"
	@echo "Bucket: $(TF_STATE_BUCKET_NAME)"
	@cd $(BOOTSTRAP_DIR) && \
		terraform init && \
		terraform apply -auto-approve \
			-var="project=$(PROJECT)" \
			-var="region=$(REGION)" \
			-var="tf_state_bucket_name=$(TF_STATE_BUCKET_NAME)"
	@echo "Terraform state bucket created successfully"

tf-init: ## Initialize Terraform with remote backend
	@echo "Initializing Terraform with remote state..."
	@if [ ! -f "$(TFVARS_FILE)" ]; then \
		echo "Error: $(TFVARS_FILE) not found. Run 'make tf-bootstrap' first."; \
		exit 1; \
	fi
	$(eval TF_STATE_BUCKET_NAME := $(shell grep '^tf_state_bucket_name' "$(TFVARS_FILE)" | awk -F '"' '{print $$2}'))
	@if [ -z "$(TF_STATE_BUCKET_NAME)" ]; then \
		echo "Error: tf_state_bucket_name not found in $(TFVARS_FILE)"; \
		exit 1; \
	fi
	@cd $(TERRAFORM_DIR) && \
		terraform init \
			-backend-config="bucket=$(TF_STATE_BUCKET_NAME)" \
			-backend-config="prefix=main"
	@if gsutil ls -l gs://$(TF_STATE_BUCKET_NAME)/main/ >/dev/null 2>&1; then \
		echo "Terraform state found in bucket"; \
	else \
		echo "No existing state found - this is normal for first run"; \
	fi
	@echo "Terraform initialized with remote state in GCS bucket: $(TF_STATE_BUCKET_NAME)"
	@echo "State path: gs://$(TF_STATE_BUCKET_NAME)/main/default.tfstate"