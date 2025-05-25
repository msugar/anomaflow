# =============================================================================
# Anomaflow Beam Pipeline Makefile
# =============================================================================

# Configuration
SHELL := /bin/bash
.DEFAULT_GOAL := help

# =============================================================================
# PATHS
# =============================================================================

PROJECT_ROOT := $(shell pwd)
SRC_DIR := $(PROJECT_ROOT)/python
REL_SRC_DIR = $(shell realpath --relative-to=$(PROJECT_ROOT) $(SRC_DIR))
DOCKER_DIR := $(PROJECT_ROOT)/docker
DATA_DIR := $(PROJECT_ROOT)/data
TERRAFORM_DIR := $(PROJECT_ROOT)/terraform

# Python
VENV_DIR = $(SRC_DIR)/.venv
REL_VENV_DIR = $(shell realpath --relative-to=$(PROJECT_ROOT) $(VENV_DIR))
PYTHON = $(VENV_DIR)/bin/python3

# Pipelines
PIPELINE := $(SRC_DIR)/anomaflow/pipeline.py
TEST_PIPELINE := $(SRC_DIR)/anomaflow/test_pipeline.py
STREAM_PIPELINE := $(SRC_DIR)/anomaflow/stream_pipeline.py

# Local data
LOCAL_INPUT_PATH := $(DATA_DIR)/input
LOCAL_OUTPUT_PATH := $(DATA_DIR)/output

# Terraform
TFVARS_FILE := $(TERRAFORM_DIR)/terraform.tfvars
TFVARS_TEMPLATE := $(TERRAFORM_DIR)/terraform.tfvars.templ
BOOTSTRAP_DIR := $(TERRAFORM_DIR)/bootstrap

# Cache file
TF_OUTPUTS_FILE := .terraform-outputs.json

# =============================================================================
# CONFIGURATION VARIABLES (Override with environment or command line)
# =============================================================================

# Pipeline configuration
WORKER_MACHINE_TYPE ?= e2-medium
MAX_WORKERS ?= 4
WINDOW_SIZE ?= 600
ZONE_SUFFIX ?=

# Docker configuration
IMAGE_NAME := anomaflow
IMAGE_TAG ?= latest

# Pattern for input files for previous hour in UTC (single date call for consistency)
INPUT_PATTERN ?= $(shell date -u --date='1 hour ago' +"year=%Y/month=%m/day=%d/hour=%H/minute=*/*.json")

# Runtime variables (loaded from Terraform outputs)
PROJECT_ID :=
REGION :=
ZONE :=
TELEMETRY_BUCKET :=
TEMP_BUCKET :=
SERVICE_ACCOUNT_EMAIL :=
NETWORK :=
SUBNET :=

# Derived variables (deferred expansion)
DOCKER_REGISTRY = $(REGION)-docker.pkg.dev/$(PROJECT_ID)/dataflow-images
IMAGE_URI = $(DOCKER_REGISTRY)/$(IMAGE_NAME):$(IMAGE_TAG)
GCS_BUCKET_INPUT = gs://$(TELEMETRY_BUCKET)
GCS_BUCKET_OUTPUT = gs://$(TELEMETRY_BUCKET)
GCS_BUCKET_TEMP = gs://$(TEMP_BUCKET)
WORKER_ZONE = "$(if $(ZONE_SUFFIX),$(REGION)-$(ZONE_SUFFIX),$(ZONE))"

# =============================================================================
# PHONY TARGETS
# =============================================================================

.PHONY: help quickstart \
		uv-sync \
		run run-gcs \
        tf-bootstrap tf-init tf-plan tf-apply tf-destroy \
        load-vars clean-cache \ 
		docker-build docker-push deploy \
		run-dataflow run-dataflow-test \
        status logs watch-logs cancel-job iap-tunnel \
		check-tools check-docker check-gcloud-auth

# =============================================================================
# HELP
# =============================================================================

help: ## Show this help message
	@echo "Anomaflow Makefile"
	@echo "=================="
	@echo "Available Commands:"
	@awk 'BEGIN {FS = ":.*##"; printf ""} /^[a-zA-Z_-]+:.*?##/ { printf "  %-25s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@echo ""
	@echo "Configuration Variables:"
	@echo "  WINDOW_SIZE=$(WINDOW_SIZE)			Window size in seconds"
	@echo "  IMAGE_TAG=$(IMAGE_TAG)			Docker image tag"
	@echo "  MAX_WORKERS=$(MAX_WORKERS)				Maximum Dataflow workers"
	@echo "  WORKER_MACHINE_TYPE=$(WORKER_MACHINE_TYPE) 	GCE machine type for workers"
	@echo "  ZONE_SUFFIX=b 			Zone suffix for worker placement"
	@echo ""
	@echo "Examples:"
	@echo "  make run WINDOW_SIZE=1800"
	@echo "  make deploy IMAGE_TAG=v1.2.3"
	@echo "  make run-dataflow IMAGE_TAG=v1.2.3 MAX_WORKERS=8 INPUT_PATTERN='year=2025/month=05/day=18/hour=*/minute=*/*.json'"

quickstart: ## Show quick start instructions
	@echo "Anomaflow Quick Start Instructions:"
	@echo "make run    	Run pipeline with DirectRunner and local data"
	@echo ""

# =============================================================================
# DEVELOPMENT
# =============================================================================

$(VENV_DIR)/bin/activate: $(SRC_DIR)/pyproject.toml
	uv sync --project $(SRC_DIR)
	touch $(VENV_DIR)/bin/activate

uv-sync: check-tools ## Sync virtual environment
	@echo "Syncing virtual environment..."
	uv sync --project $(SRC_DIR)
	touch $(VENV_DIR)/bin/activate
	@echo "Virtual environment synced."
	@echo "Run 'source $(REL_VENV_DIR)/bin/activate' to activate the virtual environment."

# =============================================================================
# TERRAFORM OUTPUTS AND VARIABLE LOADING
# =============================================================================

$(TF_OUTPUTS_FILE): $(TERRAFORM_DIR)/*.tf
	@echo "Fetching Terraform outputs..."
	@if ! terraform -chdir=$(TERRAFORM_DIR) output -json > $@ 2>/dev/null; then \
		echo "Error: Failed to read Terraform outputs. Ensure terraform is applied."; \
		rm -f $@; exit 1; \
	fi

load-vars: $(TF_OUTPUTS_FILE) # Load variables from Terraform outputs
	$(eval PROJECT_ID := $(shell jq -r '.project_id.value' $(TF_OUTPUTS_FILE)))
	$(eval REGION := $(shell jq -r '.region.value' $(TF_OUTPUTS_FILE)))
	$(eval ZONE := $(shell jq -r '.zone.value' $(TF_OUTPUTS_FILE)))
	$(eval TELEMETRY_BUCKET := $(shell jq -r '.telemetry_bucket_name.value' $(TF_OUTPUTS_FILE)))
	$(eval TEMP_BUCKET := $(shell jq -r '.dataflow_temp_bucket.value' $(TF_OUTPUTS_FILE)))
	$(eval NETWORK := $(shell jq -r '.dataflow_network.value' $(TF_OUTPUTS_FILE)))
	$(eval SUBNET := $(shell jq -r '.dataflow_subnet.value' $(TF_OUTPUTS_FILE)))
	$(eval SERVICE_ACCOUNT_EMAIL := $(shell jq -r '.dataflow_service_account_email.value' $(TF_OUTPUTS_FILE)))
	@echo "Variables loaded (Project: $(PROJECT_ID), Region: $(REGION))"

clean-cache: # Clean Terraform outputs cache
	@echo "Cleaning Terraform outputs cache..."
	@rm -f $(TF_OUTPUTS_FILE)
	@echo "Terraform outputs cache cleaned"

# =============================================================================
# TERRAFORM
# =============================================================================

tf-bootstrap: check-tools check-gcloud-auth ## Bootstrap Terraform state bucket
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
		echo "One or more required variables are missing in $(TFVARS_FILE)"; \
		echo "Required format:"; \
		echo '    project               = "your-gcp-project-id"'; \
		echo '    region                = "your-region"'; \
		echo '    tf_state_bucket_name  = "your-terraform-state-bucket"'; \
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
	@echo "Terraform Bootstrapping complete"

tf-init: check-tools check-gcloud-auth ## Initialize Terraform with remote backend
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
		echo "No existing state found - normal for first run"; \
	fi
	@echo "Terraform initialized with remote state"
	@echo "State location: gs://$(TF_STATE_BUCKET_NAME)/main/default.tfstate"

tf-plan: tf-init clean-cache ## Run terraform plan
	@echo "Running Terraform plan..."
	@cd $(TERRAFORM_DIR) && terraform plan -var-file=terraform.tfvars

tf-apply: tf-init clean-cache ## Apply terraform changes
	@echo "Applying Terraform changes..."
	@cd $(TERRAFORM_DIR) && terraform apply -var-file=terraform.tfvars

tf-destroy: tf-init clean-cache ## Destroy terraform resources (DESTRUCTIVE)
	@echo "This will destroy all Terraform-managed resources."
	@echo "This operation cannot be undone and may result in data loss."
	@read -p "Are you sure you want to destroy all resources? [y/N] " -n 1 -r; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		echo ""; \
		cd $(TERRAFORM_DIR) && terraform destroy -var-file=terraform.tfvars; \
	else \
		echo ""; echo "Destroy cancelled"; \
	fi

# =============================================================================
# BUILD AND DEPLOY CONTAINERIZED IMAGE WITH PIPELINE CODE AND DEPENDENCIES
# =============================================================================

docker-build: check-docker $(VENV_DIR)/bin/activate load-vars ## Build image using Docker
	@echo "Building Docker image: $(IMAGE_URI)"
	@[ -f "docker/Dockerfile" ] || (echo "Error: Dockerfile not found in docker/ folder" && exit 1)
	docker build -f docker/Dockerfile -t $(IMAGE_URI) $(SRC_DIR)
	@echo "Docker image built successfully"

docker-push: docker-build ## Build and push image using Docker
	@echo "Pushing Docker image to Artifact Registry..."
	@gcloud auth configure-docker $(REGION)-docker.pkg.dev --quiet
	docker push $(IMAGE_URI)
	@echo "Docker image pushed successfully: $(IMAGE_URI)"

deploy: check-tools $(VENV_DIR)/bin/activate check-gcloud-auth load-vars ## Build and push image using Google Cloud Build
	@echo "Building Docker image using Cloud Build: $(IMAGE_URI)"
	@[ -f "docker/Dockerfile" ] || (echo "Error: Dockerfile not found in docker/ folder" && exit 1)
	@[ -f "cloud-build/cloudbuild.yaml" ] || (echo "Error: cloudbuild.yaml not found in cloud-build/ folder" && exit 1)
	gcloud builds submit \
		--config=cloud-build/cloudbuild.yaml \
		--substitutions=_IMAGE_URI=$(IMAGE_URI),_SRC_DIR=$(REL_SRC_DIR) \
		--project=$(PROJECT_ID) \
		--region=$(REGION) \
		.
	@echo "Docker image built and pushed successfully using Cloud Build"

# =============================================================================
# BEAM PIPELINE EXECUTION WITH DIRECT RUNNER
# =============================================================================

run: check-tools $(VENV_DIR)/bin/activate ## Run pipeline with DirectRunner and local data
	@echo "Starting Direct batch run and local data..."
	$(PYTHON) $(PIPELINE) \
		--runner=DirectRunner \
		--input_path="$(LOCAL_INPUT_PATH)/*.json" \
		--output_path="$(LOCAL_OUTPUT_PATH)/" \
		--window_size=$(WINDOW_SIZE)
	@echo "Direct run complete"

run-gcs: check-tools $(VENV_DIR)/bin/activate check-gcloud-auth load-vars ## Run pipeline with DirectRunner and data from GCS
	@echo "Starting Direct batch run and data from GCS..."
	$(PYTHON) $(PIPELINE) \
		--runner=DirectRunner \
		--input_path="$(GCS_BUCKET_INPUT)/input/$(INPUT_PATTERN)" \
		--output_path="$(GCS_BUCKET_OUTPUT)/output/" \
		--window_size=$(WINDOW_SIZE)
	@echo "Direct run complete"

# =============================================================================
# BEAM PIPELINE EXECUTION WITH DATAFLOW RUNNER
# =============================================================================

run-dataflow: check-tools $(VENV_DIR)/bin/activate check-gcloud-auth load-vars ## Run pipeline with DataflowRunner (batch)
	@echo "Starting Dataflow batch job..."
	@echo "Image: $(IMAGE_URI)"
	$(PYTHON) $(PIPELINE) \
		--runner=DataflowRunner \
		--project="$(PROJECT_ID)" \
		--region="$(REGION)" \
		--network="$(NETWORK)" \
		--subnetwork="regions/$(REGION)/subnetworks/$(SUBNET)" \
		--experiments=use_network_tags="dataflow" \
		--experiments=use_runner_v2 \
		--no_use_public_ips \
		--num_workers=1 \
		--max_num_workers="$(MAX_WORKERS)" \
		--worker_zone=$(WORKER_ZONE) \
		--machine_type="$(WORKER_MACHINE_TYPE)" \
		--service_account_email="$(SERVICE_ACCOUNT_EMAIL)" \
		--temp_location="$(GCS_BUCKET_TEMP)/temp/" \
		--staging_location="$(GCS_BUCKET_TEMP)/staging/" \
		--sdk_container_image="$(IMAGE_URI)" \
		--input_path="$(GCS_BUCKET_INPUT)/input/$(INPUT_PATTERN)" \
		--output_path="$(GCS_BUCKET_OUTPUT)/output/" \
		--window_size=$(WINDOW_SIZE)
	@echo "Dataflow job complete"

run-dataflow-test: check-tools $(VENV_DIR)/bin/activate check-gcloud-auth load-vars ## Run test pipeline with DataflowRunner (batch)
	@echo "Running Dataflow test batch job..."
	$(PYTHON) $(TEST_PIPELINE) \
		--runner=DataflowRunner \
		--project="$(PROJECT_ID)" \
		--region="$(REGION)" \
		--network="$(NETWORK)" \
		--subnetwork="regions/$(REGION)/subnetworks/$(SUBNET)" \
		--experiments=use_network_tags="dataflow" \
		--experiments=use_runner_v2 \
		--experiments=disable_metric_annotations \
		--no_use_public_ips \
		--num_workers=1 \
		--max_num_workers="$(MAX_WORKERS)" \
		--worker_zone=$(WORKER_ZONE) \
		--machine_type="$(WORKER_MACHINE_TYPE)" \
		--service_account_email="$(SERVICE_ACCOUNT_EMAIL)" \
		--temp_location="$(GCS_BUCKET_TEMP)/temp/" \
		--staging_location="$(GCS_BUCKET_TEMP)/staging/" \
		--output="$(GCS_BUCKET_OUTPUT)/test-output"
	@echo "Dataflow test job complete"

# =============================================================================
# MONITORING AND OPERATIONS
# =============================================================================	

status: load-vars ## Show status of most recent Dataflow job
	@echo "Fetching recent Dataflow job logs..."
	@JOB_ID=$$(gcloud dataflow jobs list --region=$(REGION) --limit=1 --format="value(JOB_ID)" 2>/dev/null); \
	if [ -n "$$JOB_ID" ]; then \
		gcloud dataflow jobs show $$JOB_ID --region=$(REGION); \
	else \
		echo "No Dataflow jobs found"; \
	fi

iap-tunnel: load-vars ## Create IAP tunnel to bindplane-server
	@echo "Creating IAP tunnel to bindplane-server on localhost:3001..."
	@echo "Project: $(PROJECT_ID), Zone: $(ZONE)"
	@echo "Press Ctrl+C to stop the tunnel"
	gcloud compute start-iap-tunnel bindplane-server 3001 \
		--local-host-port=localhost:3001 \
		--zone="$(ZONE)" \
		--project="$(PROJECT_ID)"

# =============================================================================
# VALIDATION CHECKS
# =============================================================================

check-tools: # Check required tools are installed
	@echo "Checking required tools are installed..."
	@command -v python3 >/dev/null || (echo "Error: python3 not found" && exit 1)
	@command -v uv >/dev/null || (echo "Error: uv not found" && exit 1)
	@command -v terraform >/dev/null || (echo "Error: terraform not found" && exit 1)
	@command -v gcloud >/dev/null || (echo "Error: gcloud not found" && exit 1)
	@command -v jq >/dev/null || (echo "Error: jq not found" && exit 1)
	@echo "Required tools found"

check-docker: # Check if Docker is available
	@command -v docker >/dev/null || (echo "Warning: Docker not found - use 'make deploy' instead" && exit 1)
	@echo "Docker found"

check-gcloud-auth: # Check gcloud authentication
	@echo "Checking gcloud authentication..."
	@gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q . || \
		(echo "Error: No active gcloud authentication. Run 'gcloud auth login'" && exit 1)
	@echo "gcloud authentication validated"