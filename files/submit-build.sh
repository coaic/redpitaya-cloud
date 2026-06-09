#!/usr/bin/env bash
# submit-build.sh - submit one Vivado build as a Cloud Batch job.
#
# Usage:   ./submit-build.sh <git-url> [git-ref]
# Example: ./submit-build.sh git@gitlab.com:shane/redpitaya-project.git main

set -euo pipefail

# ---- Config ----------------------------------------------------------

PROJECT_ID="${GCP_PROJECT:?set GCP_PROJECT env var}"
REGION="${GCP_REGION:-australia-southeast1}"
GIT_REPO="${1:?usage: submit-build.sh <git-url> [git-ref]}"
GIT_REF="${2:-main}"

JOB_NAME="vivado-$(date +%Y%m%d-%H%M%S)"
BUCKET="${PROJECT_ID}-fpga-artifacts"
SA_EMAIL="fpga-builder@${PROJECT_ID}.iam.gserviceaccount.com"
IMAGE_URI="projects/${PROJECT_ID}/global/images/family/vivado-redpitaya"

# ---- Build script that runs on the VM -------------------------------

# Note: ${BATCH_TASK_INDEX} is interpolated by the Batch agent at runtime,
# not by the local shell. We escape it with single quotes around the heredoc
# below (only for that variable's containing block).
read -r -d '' BUILD_SCRIPT <<EOF || true
#!/bin/bash
set -e
exec > >(tee /var/log/build.log) 2>&1

echo "Batch task: \${BATCH_TASK_INDEX} of \${BATCH_TASK_COUNT}"

cd /tmp
git clone --depth=1 --branch "${GIT_REF}" "${GIT_REPO}" project
cd project

source /tools/Xilinx/Vivado/2020.1/settings64.sh

make fpga || BUILD_FAILED=1

gsutil cp /var/log/build.log "gs://${BUCKET}/${JOB_NAME}/"
gsutil -m cp -r out/*.bit "gs://${BUCKET}/${JOB_NAME}/" 2>/dev/null || true

[ -z "\${BUILD_FAILED:-}" ]
EOF

# ---- Job spec --------------------------------------------------------

# Properly escape the script for JSON embedding
SCRIPT_JSON=$(printf '%s' "${BUILD_SCRIPT}" | jq -Rs .)

CONFIG=$(cat <<EOF
{
  "taskGroups": [
    {
      "taskSpec": {
        "runnables": [
          { "script": { "text": ${SCRIPT_JSON} } }
        ],
        "computeResource": {
          "cpuMilli": 4000,
          "memoryMib": 32768
        },
        "maxRetryCount": 2,
        "maxRunDuration": "10800s"
      },
      "taskCount": 1,
      "parallelism": 1
    }
  ],
  "allocationPolicy": {
    "instances": [
      {
        "policy": {
          "machineType": "n2-custom-4-32768",
          "provisioningModel": "SPOT",
          "bootDisk": {
            "image": "${IMAGE_URI}",
            "type": "pd-balanced",
            "sizeGb": 120
          }
        }
      }
    ],
    "serviceAccount": {
      "email": "${SA_EMAIL}",
      "scopes": ["https://www.googleapis.com/auth/cloud-platform"]
    },
    "network": {
      "networkInterfaces": [
        {
          "network": "global/networks/default",
          "subnetwork": "regions/${REGION}/subnetworks/default",
          "noExternalIpAddress": true
        }
      ]
    },
    "labels": { "workload": "fpga-build" }
  },
  "logsPolicy": { "destination": "CLOUD_LOGGING" }
}
EOF
)

# ---- Submit ----------------------------------------------------------

echo "Submitting Batch job ${JOB_NAME}..."
echo "${CONFIG}" | gcloud batch jobs submit "${JOB_NAME}" \
  --project="${PROJECT_ID}" \
  --location="${REGION}" \
  --config=-

echo
echo "Job submitted. Useful commands:"
echo "  Status:  gcloud batch jobs describe ${JOB_NAME} --location=${REGION}"
echo "  Logs:    gcloud logging read 'resource.type=batch.googleapis.com/Job AND labels.job_uid:${JOB_NAME}' --limit=50"
echo "  Console: https://console.cloud.google.com/batch/jobsDetail/regions/${REGION}/jobs/${JOB_NAME}?project=${PROJECT_ID}"
