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

# Vivado strategies indexed by BATCH_TASK_INDEX (0..7).
# Strategies map to Vivado's built-in synth/impl directives.
# See UG904 and `report_strategy` in Vivado for the full list.
read -r -d '' BUILD_SCRIPT <<'EOF' || true
#!/bin/bash
set -e
exec > >(tee /var/log/build.log) 2>&1

export HOME=/root
GCP_SDK_BIN=$(dirname $(command -v gsutil 2>/dev/null || echo /usr/lib/google-cloud-sdk/bin/gsutil))

STRATEGIES=(
  "default:default"
  "Flow_PerfOptimized_high:Performance_Explore"
  "Flow_PerfThresholdCarry:Performance_ExtraTimingOpt"
  "Flow_AlternateRoutability:Performance_NetDelay_high"
  "Flow_RuntimeOptimized:Performance_RefinePlacement"
  "Flow_AreaOptimized_high:Area_Explore"
  "Flow_AreaOptimized_medium:Area_ExploreSequential"
  "Flow_AreaMultThresholdDSP:Performance_RetimingPostRoutePhysOpt"
)

PAIR="${STRATEGIES[$BATCH_TASK_INDEX]}"
SYNTH_STRAT="${PAIR%%:*}"
IMPL_STRAT="${PAIR##*:}"

echo "Task ${BATCH_TASK_INDEX}: synth=${SYNTH_STRAT} impl=${IMPL_STRAT}"

cd /tmp
rm -rf project
git clone --depth=1 --branch "GIT_REF_PLACEHOLDER" "GIT_REPO_PLACEHOLDER" project
cd project

source /tools/Xilinx/Vivado/2020.1/settings64.sh
export PATH="${GCP_SDK_BIN}:${PATH}"

# Pass strategies via Vivado env vars. The Red Pitaya TCL scripts don't read
# these by default — patch red_pitaya_vivado_Z20_G2.tcl to honour them if
# you want strategy sweeps to take effect.
export VIVADO_SYNTH_STRATEGY="${SYNTH_STRAT}"
export VIVADO_IMPL_STRATEGY="${IMPL_STRAT}"

# Build bitstream only (not FSBL/DTS which require xsct/SDK)
make PRJ=v0.94 MODEL=Z20_G2 prj/v0.94/out/red_pitaya.bit || BUILD_FAILED=1

# Tag artifacts with strategy index so they don't collide
TAG="task${BATCH_TASK_INDEX}_${SYNTH_STRAT}_${IMPL_STRAT}"
gsutil cp /var/log/build.log "gs://BUCKET_PLACEHOLDER/JOB_NAME_PLACEHOLDER/${TAG}/"
gsutil -m cp -r prj/v0.94/out/*.bit "gs://BUCKET_PLACEHOLDER/JOB_NAME_PLACEHOLDER/${TAG}/" 2>/dev/null || true
gsutil -m cp -r prj/v0.94/out/*.rpt "gs://BUCKET_PLACEHOLDER/JOB_NAME_PLACEHOLDER/${TAG}/" 2>/dev/null || true

# Extract WNS (Worst Negative Slack) from the timing report and stash it
WNS=$(grep -Po 'WNS\(ns\)\s*\K-?[\d.]+' prj/v0.94/out/*.rpt 2>/dev/null | head -1 || echo "N/A")
echo "${TAG},${WNS}" | gsutil cp - "gs://BUCKET_PLACEHOLDER/JOB_NAME_PLACEHOLDER/${TAG}/wns.csv"

[ -z "${BUILD_FAILED:-}" ]
EOF

# Substitute placeholders that aren't shell vars on the VM
BUILD_SCRIPT="${BUILD_SCRIPT//GIT_REF_PLACEHOLDER/${GIT_REF}}"
BUILD_SCRIPT="${BUILD_SCRIPT//GIT_REPO_PLACEHOLDER/${GIT_REPO}}"
BUILD_SCRIPT="${BUILD_SCRIPT//BUCKET_PLACEHOLDER/${BUCKET}}"
BUILD_SCRIPT="${BUILD_SCRIPT//JOB_NAME_PLACEHOLDER/${JOB_NAME}}"

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
