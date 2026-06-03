# Getting Started

## Prerequisites

Install these on your Mac (Apple Silicon):

```bash
brew install google-cloud-sdk terraform packer yq jq
```

Authenticate with GCP:

```bash
gcloud auth login
gcloud auth application-default login
```

## Step 1 — GCP Project

Create or select a GCP project. Note the project ID.

```bash
gcloud projects create YOUR_PROJECT_ID --name="RedPitaya FPGA Builds"
gcloud config set project YOUR_PROJECT_ID
```

Enable billing on the project in the GCP Console before proceeding.

## Step 2 — Configure Your Environment

Copy and edit the dev environment config:

```bash
cp infra/environments/dev.yml infra/environments/dev.yml
# edit infra/environments/dev.yml — set project_id and submitter_email
```

Key fields to set:

```yaml
project_id: your-gcp-project-id
submitter_email: your-email@example.com
billing_account: ""   # optional — set to enable $20 budget alert
```

## Step 3 — Bootstrap Terraform State

The Terraform state bucket can't be managed by the same Terraform workspace that uses it as a backend, so it's created once via a bootstrap script:

```bash
./scripts/bootstrap.sh dev
```

This creates `<project>-fpga-tfstate` with versioning enabled. Then initialise Terraform:

```bash
cd infra
./tf.sh dev init    # wires up GCS backend and downloads providers
```

## Step 4 — Apply Terraform Infrastructure

```bash
./tf.sh dev plan    # review what will be created
./tf.sh dev apply
```

This creates:
- GCS bucket `<project>-fpga-artifacts` (30-day artifact lifecycle)
- GCS bucket `<project>-fpga-installer` (permanent — Vivado installer lives here)
- Service account `fpga-builder@<project>.iam.gserviceaccount.com`
- IAM bindings for the builder SA and your submitter email
- Optional billing budget

## Step 5 — Upload the Vivado Installer to GCS

Xilinx (AMD) requires a free account to download the installer. Download
`Xilinx_Unified_2020.1_*.tar.gz` from the Xilinx download portal, then upload
it to the dedicated installer bucket (permanent, no lifecycle deletion):

```bash
INSTALLER_BUCKET=$(cd infra && terraform output -raw installer_bucket)
gsutil cp ~/Downloads/Xilinx_Unified_2020.1_*.tar.gz "gs://${INSTALLER_BUCKET}/"
```

Note the `gs://` URL — you'll need it for the Packer step.

## Step 6 — Bake the Vivado Machine Image

```bash
cd packer
packer init .
packer build \
  -var project_id=YOUR_PROJECT_ID \
  -var "vivado_installer_gcs=gs://YOUR_PROJECT_ID-fpga-installer/Xilinx_Unified_2020.1_*.tar.gz" \
  vivado-image.pkr.hcl
```

This takes ~45 minutes (install time). The resulting image is stored in GCP
under the image family `vivado-redpitaya` and reused by every subsequent build
job — you only run Packer again if you need a different Vivado version.

## Step 7 — Submit Your First Build

```bash
cd ../scripts
export GCP_PROJECT=YOUR_PROJECT_ID

./submit-build.sh git@github.com:YOUR_ORG/YOUR_REPO.git main
```

Monitor progress:

```bash
# Status
gcloud batch jobs list --location=australia-southeast1

# Logs (replace JOB_NAME with the name printed by submit-build.sh)
gcloud logging read \
  'resource.type="batch.googleapis.com/Job" AND labels."job_uid"="JOB_NAME"' \
  --limit=100 --format="value(textPayload)"

# Fetch bitstream when done
gsutil ls gs://YOUR_PROJECT-fpga-artifacts/
gsutil cp gs://YOUR_PROJECT-fpga-artifacts/JOB_NAME/*.bit ./
```
