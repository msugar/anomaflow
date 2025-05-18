# Makefile for running Anomaflow Beam pipeline

# Paths
PYTHON_DIR := python
MAIN_SCRIPT := $(PYTHON_DIR)/anomaflow/pipeline.py

# Local paths
LOCAL_INPUT_PATH := data/input
LOCAL_OUTPUT_PATH := data/output

# Beam config
WINDOW_SIZE := 600 # Default window size in seconds

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
GCS_INPUT_PATH :=
GCS_OUTPUT_PATH :=
GCS_TEMP_PATH :=

.PHONY: help local dataflow load-terraform-outputs cleanup iap-tunnel tf-bootstrap tf-init remote dataflow-stream

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

remote: load-terraform-outputs
	python3 $(MAIN_SCRIPT) \
		--runner=DirectRunner \
		--input_path="$(GCS_INPUT_PATH)/year=2025/month=05/day=18/hour=04/minute=*/*.json" \
		--output_path="$(GCS_OUTPUT_PATH)/" \
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
	$(eval GCS_INPUT_PATH := gs://$(TELEMETRY_BUCKET)/input/)
	$(eval GCS_OUTPUT_PATH := gs://$(TELEMETRY_BUCKET)/output)
	$(eval GCS_TEMP_PATH := gs://$(TEMP_BUCKET))

dataflow: load-terraform-outputs
	python3 $(MAIN_SCRIPT) \
		--runner=DataflowRunner \
		--project="$(PROJECT_ID)" \
		--region="$(REGION)" \
		--temp_location="$(GCS_TEMP_PATH)/temp/" \
		--staging_location="$(GCS_TEMP_PATH)/staging/" \
		--input_path="$(GCS_INPUT_PATH)/year=2025/month=05/day=18/hour=*/minute=*/*.json" \
		--output_path="$(GCS_OUTPUT_PATH)/" \
		--window_size=$(WINDOW_SIZE) \
		--max_num_workers=4 \
		--num_workers=1

dataflow-stream: load-terraform-outputs
	python3 $(MAIN_SCRIPT) \
		--runner=DataflowRunner \
		--project="$(PROJECT_ID)" \
		--region="$(REGION)" \
		--temp_location="$(GCS_TEMP_PATH)/temp/" \
		--staging_location="$(GCS_TEMP_PATH)/staging/" \
		--input_path="$(GCS_INPUT_PATH)/year=2025/month=05/day=18/hour=*/minute=*/*.json" \
		--output_path="$(GCS_OUTPUT_PATH)/" \
		--window_size=$(WINDOW_SIZE) \
		--streaming \
		--max_num_workers=4 \
		--num_workers=1


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