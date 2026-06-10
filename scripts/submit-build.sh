#!/usr/bin/env bash
# submit-build.sh - submit one Vivado build as a Cloud Batch job.
#
# Usage:   ./submit-build.sh <git-url> [git-ref]
# Example: ./submit-build.sh git@gitlab.com:shane/redpitaya-project.git main

set -euo pipefail

PROJECT_ID="${GCP_PROJECT:?set GCP_PROJECT env var}"
REGION="${GCP_REGION:-australia-southeast1}"
GIT_REPO="${1:?usage: submit-build.sh <git-url> [git-ref]}"
GIT_REF="${2:-main}"

PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")
JOB_NAME="vivado-$(date +%Y%m%d-%H%M%S)"
BUCKET="${PROJECT_ID}-${PROJECT_NUMBER}-fpga-artifacts"
SA_EMAIL="fpga-builder@${PROJECT_ID}.iam.gserviceaccount.com"
IMAGE_URI="projects/${PROJECT_ID}/global/images/family/vivado-2020-1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Substitute @@MARKER@@ values into the task script, then JSON-encode for embedding.
BUILD_SCRIPT=$(sed \
  -e "s|@@BUCKET@@|${BUCKET}|g" \
  -e "s|@@JOB_NAME@@|${JOB_NAME}|g" \
  -e "s|@@GIT_REF@@|${GIT_REF}|g" \
  -e "s|@@GIT_REPO@@|${GIT_REPO}|g" \
  "${SCRIPT_DIR}/build-task.sh")
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
            "sizeGb": 200
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
