# Makefile for running Anomaflow Beam pipeline

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

# These will be set by the 'load-terraform-outputs' target
PROJECT_ID :=
REGION :=
ZONE :=
TELEMETRY_BUCKET :=
TEMP_BUCKET :=
GCS_BUCKET_INPUT :=
GCS_BUCKET_OUTPUT :=
GCS_BUCKET_TEMP :=

# Beam config
# Default window size in seconds
WINDOW_SIZE := 600

# Docker config  (note the use of the deferred simple variable expansion, a.k.a. 'lazy' expansion)
IMAGE_NAME := anomaflow
IMAGE_TAG ?= latest                         # allow override: make build-container IMAGE_TAG=dev
IMAGE_REPO = $(REGION)-docker.pkg.dev/$(PROJECT_ID)/dataflow-images
IMAGE_URI  = $(IMAGE_REPO)/$(IMAGE_NAME):$(IMAGE_TAG)


.PHONY: help local dataflow load-terraform-outputs cleanup iap-tunnel tf-bootstrap tf-init remote dataflow-stream dataflow-test build-container

help:
	@echo "Usage:"
	@echo "  make local       Run pipeline locally"
	@echo "  make dataflow    Run pipeline on Google Cloud Dataflow"
	@echo "  make iap-tunnel  Create IAP tunnel to bindplane-server"
	@echo ""
	@echo "Variables:"
	@echo "  Override any default by passing VAR=value, e.g.: make dataflow WINDOW_SIZE=120"

# Clean up previous local outputs
cleanup:
	@echo "Cleaning up local output directory..."
	rm -rf $(LOCAL_OUTPUT_PATH)/*

# Run the pipeline locally after cleaning output	
local: cleanup
	python3 $(MAIN_SCRIPT) \
		--runner=DirectRunner \
		--input_path="$(LOCAL_INPUT_PATH)/*.json" \
		--output_path="$(LOCAL_OUTPUT_PATH)/" \
		--window_size=$(WINDOW_SIZE)

# 		--input_path="$(GCS_BUCKET_INPUT)/input/year=2025/month=05/day=18/hour=04/minute=*/*.json" \
#
remote: load-terraform-outputs
	python3 $(MAIN_SCRIPT) \
		--runner=DirectRunner \
		--input_path="gs://decoded-badge-459922-v4-telemetry/input/year=2025/month=05/day=18/hour=23/minute=44/metrics_396542527.json" \
		--output_path="$(GCS_BUCKET_OUTPUT)/output/" \
		--window_size=$(WINDOW_SIZE)

# Sets variables by reading Terraform outputs and exporting them to Make
load-terraform-outputs:
	@echo "Fetching Terraform outputs..."
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

# 		--input_path="$(GCS_BUCKET_INPUT)/input/year=2025/month=05/day=18/hour=*/minute=*/*.json" \
#
dataflow: load-terraform-outputs
	python3 $(MAIN_SCRIPT) \
		--runner=DataflowRunner \
		--project="$(PROJECT_ID)" \
		--region="$(REGION)" \
		--network="$(DATAFLOW_NETWORK)" \
		--subnetwork="regions/$(REGION)/subnetworks/$(DATAFLOW_SUBNET)" \
		--service_account_email="$(DATAFLOW_SERVICE_ACCOUNT_EMAIL)" \
		--temp_location="$(GCS_BUCKET_TEMP)/temp/" \
		--staging_location="$(GCS_BUCKET_TEMP)/staging/" \
		--input_path="gs://decoded-badge-459922-v4-telemetry/input/year=2025/month=05/day=18/hour=23/minute=44/metrics_396542527.json" \
		--output_path="$(GCS_BUCKET_OUTPUT)/output/" \
		--window_size=$(WINDOW_SIZE) \
		--max_num_workers=3 \
		--num_workers=1 \
		$(WORKER_ZONE_FLAG) --machine_type="e2-medium"

dataflow2: load-terraform-outputs
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
		--input_path="gs://decoded-badge-459922-v4-telemetry/input/year=2025/month=05/day=18/hour=23/minute=44/metrics_396542527.json" \
		--output_path="$(GCS_BUCKET_OUTPUT)/output/" \
		--window_size=$(WINDOW_SIZE) \
		--max_num_workers=3 \
		--num_workers=1 \
		$(WORKER_ZONE_FLAG) --machine_type="e2-medium"

dataflow-stream: load-terraform-outputs
	python3 $(MAIN_SCRIPT) \
		--runner=DataflowRunner \
		--project="$(PROJECT_ID)" \
		--region="$(REGION)" \
		--temp_location="$(GCS_BUCKET_TEMP)/temp/" \
		--staging_location="$(GCS_BUCKET_TEMP)/staging/" \
		--input_path="$(GCS_BUCKET_INPUT)/input/year=2025/month=05/day=18/hour=*/minute=*/*.json" \
		--output_path="$(GCS_BUCKET_OUTPUT)/output/" \
		--window_size=$(WINDOW_SIZE) \
		--streaming \
		--max_num_workers=3 \
		--num_workers=1 \
		$(WORKER_ZONE_FLAG)

dataflow-test: load-terraform-outputs
	python3 $(TEST_SCRIPT) \
		--runner=DataflowRunner \
		--project="$(PROJECT_ID)" \
		--region="$(REGION)" \
		--network="$(DATAFLOW_NETWORK)" \
		--subnetwork="regions/$(REGION)/subnetworks/$(DATAFLOW_SUBNET)" \
		--service_account_email="$(DATAFLOW_SERVICE_ACCOUNT_EMAIL)" \
		--temp_location="$(GCS_BUCKET_TEMP)/temp/" \
		--staging_location="$(GCS_BUCKET_TEMP)/staging/" \
		--output="$(GCS_BUCKET_OUTPUT)/test-output" \
		--max_num_workers=3 \
		--num_workers=1 \
		$(WORKER_ZONE_FLAG)


# Create IAP tunnel to the bindplane-server GCE instance
iap-tunnel: load-terraform-outputs
	@echo "Creating IAP tunnel to bindplane-server on localhost:3001..."
	gcloud compute start-iap-tunnel bindplane-server 3001 \
		--local-host-port=localhost:3001 \
		--zone="$(ZONE)" \
		--project="$(PROJECT_ID)"

# Bootstrap the Terraform state bucket
tf-bootstrap:
	@echo "Bootstrapping Terraform state bucket..."
	@# Check for tfvars existence
	@if [ ! -f "$(TFVARS_FILE)" ]; then \
		echo "Missing file: $(TFVARS_FILE)"; \
		echo "Please create it by copying the template and filling in values:"; \
		echo ""; \
		echo "    cp $(TFVARS_TEMPLATE) $(TFVARS_FILE)"; \
		echo "    # Then edit $(TFVARS_FILE) with your GCP project info."; \
		echo ""; \
		exit 1; \
	fi
	@# Extract variables
	$(eval PROJECT := $(shell grep '^project' "$(TFVARS_FILE)" | awk -F '"' '{print $$2}'))
	$(eval REGION := $(shell grep '^region' "$(TFVARS_FILE)" | awk -F '"' '{print $$2}'))
	$(eval TF_STATE_BUCKET_NAME := $(shell grep '^tf_state_bucket_name' "$(TFVARS_FILE)" | awk -F '"' '{print $$2}'))
	@# Validate variables
	@if [ -z "$(PROJECT)" ] || [ -z "$(REGION)" ] || [ -z "$(TF_STATE_BUCKET_NAME)" ]; then \
		echo "One or more required variables are missing or malformed in $(TFVARS_FILE)."; \
		echo "Make sure it includes lines like:"; \
		echo '    project               = "your-gcp-project-id"'; \
		echo '    region                = "your-region"'; \
		echo '    tf_state_bucket_name  = "your-terraform-state-bucket"'; \
		echo ""; \
		exit 1; \
	fi
	@echo "  Project: $(PROJECT)"
	@echo "  Region: $(REGION)"
	@echo "  Bucket: $(TF_STATE_BUCKET_NAME)"
	@cd $(BOOTSTRAP_DIR) && \
		terraform init && \
		terraform apply -auto-approve \
			-var="project=$(PROJECT)" \
			-var="region=$(REGION)" \
			-var="tf_state_bucket_name=$(TF_STATE_BUCKET_NAME)"
	@echo "Terraform state bucket created successfully."

# Initialize Terraform with remote backend
tf-init:
	@echo "Initializing Terraform with remote state..."
	@# Extract bucket name
	$(eval TF_STATE_BUCKET_NAME := $(shell grep '^tf_state_bucket_name' "$(TFVARS_FILE)" | awk -F '"' '{print $$2}'))
	@if [ -z "$(TF_STATE_BUCKET_NAME)" ]; then \
		echo "tf_state_bucket_name not found in $(TFVARS_FILE)"; \
		exit 1; \
	fi
	@cd $(TERRAFORM_DIR) && \
		terraform init \
			-backend-config="bucket=$(TF_STATE_BUCKET_NAME)" \
			-backend-config="prefix=main"
	@gsutil ls -l gs://$(TF_STATE_BUCKET_NAME)/main/
	@echo "Terraform initialized with remote state in GCS bucket: $(TF_STATE_BUCKET_NAME)"
	@echo "   State path: gs://$(TF_STATE_BUCKET_NAME)/main/default.tfstate"

# Build and push Docker image to Artifact Registry
# Note: This target requires Docker and gcloud to be installed and configured
#       with the correct permissions to push to the Artifact Registry.
#       Ensure you have the correct IAM roles assigned to your gcloud account.
#       For example, roles/artifactregistry.writer or roles/storage.admin.
#       Also, ensure Docker is authenticated with gcloud.
#       You can do this by running: gcloud auth configure-docker $(REGION)-docker.pkg.dev
#       before running this target.
build-container: load-terraform-outputs
	@echo "Building Docker image..."
	docker build -f docker/Dockerfile -t $(IMAGE_URI) .
	@echo "Pushing Docker image to Artifact Registry..."
	gcloud auth configure-docker $(REGION)-docker.pkg.dev
	docker push $(IMAGE_URI)
	@echo "Image pushed: $(IMAGE_URI)"