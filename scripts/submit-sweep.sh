#!/usr/bin/env bash
# submit-sweep.sh - run the same build under multiple Vivado strategies
# in parallel, then compare timing/utilisation results.
#
# This is the killer feature of Batch over a single-VM script: 8 spot VMs
# kick off concurrently, each tries a different synth/PnR strategy, and
# you pick the winner.
#
# Usage:   ./submit-sweep.sh <git-url> [git-ref]

set -euo pipefail

PROJECT_ID="${GCP_PROJECT:?set GCP_PROJECT env var}"
REGION="${GCP_REGION:-australia-southeast1}"
GIT_REPO="${1:?usage: submit-sweep.sh <git-url> [git-ref]}"
GIT_REF="${2:-main}"

PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")
JOB_NAME="vivado-sweep-$(date +%Y%m%d-%H%M%S)"
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
  "${SCRIPT_DIR}/sweep-task.sh")
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
      "taskCount": 8,
      "parallelism": 8
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
    "labels": { "workload": "fpga-sweep" }
  },
  "logsPolicy": { "destination": "CLOUD_LOGGING" }
}
EOF
)

echo "Submitting sweep ${JOB_NAME} (8 parallel tasks)..."
echo "${CONFIG}" | gcloud batch jobs submit "${JOB_NAME}" \
  --project="${PROJECT_ID}" \
  --location="${REGION}" \
  --config=-

echo
echo "When done, compare WNS across strategies:"
echo "  gsutil cat gs://${BUCKET}/${JOB_NAME}/*/wns.csv"
