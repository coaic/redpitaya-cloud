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

# Batch VMs may not set HOME; Vivado requires it to expand ~/.oasys paths
export HOME=/root

# Upload helper — uses curl + GCE metadata token (avoids gsutil/snap issues)
gcs_upload() {
  local src="\$1" dst="\$2"
  local token
  token=\$(curl -sf \
    -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
  local object
  object=\$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "\${dst}")
  curl -sf -X POST \
    -H "Authorization: Bearer \${token}" \
    -H "Content-Type: application/octet-stream" \
    --data-binary "@\${src}" \
    "https://storage.googleapis.com/upload/storage/v1/b/${BUCKET}/o?uploadType=media&name=\${object}" \
    > /dev/null && echo "Uploaded \${src} -> gs://${BUCKET}/\${dst}" || echo "WARNING: upload failed for \${src}"
}

echo "Batch task: \${BATCH_TASK_INDEX} of \${BATCH_TASK_COUNT}"

cd /tmp
rm -rf project   # clean up from any prior retry attempt
git clone --depth=1 --branch "${GIT_REF}" "${GIT_REPO}" project
cd project

source /tools/Xilinx/Vivado/2020.1/settings64.sh

# Build bitstream only (not FSBL/DTS which require xsct/SDK)
make PRJ=v0.94 MODEL=Z20_G2 prj/v0.94/out/red_pitaya.bit || BUILD_FAILED=1

# Upload artifacts via curl + GCE metadata token (no gsutil dependency)
gcs_upload /var/log/build.log "${JOB_NAME}/build.log"
for f in prj/v0.94/out/*.bit; do
  [ -f "\$f" ] && gcs_upload "\$f" "${JOB_NAME}/\$(basename \$f)"
done

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
            "sizeGb": 160
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
