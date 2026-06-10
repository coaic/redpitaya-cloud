#!/bin/bash
# sweep-task.sh — runs on the Cloud Batch VM (one task per Vivado strategy).
# @@MARKER@@ values are substituted by submit-sweep.sh at submission time.
# Do not run directly.
set -e
exec > >(tee /var/log/build.log) 2>&1

export HOME=/root
GCP_SDK_BIN=$(dirname "$(command -v gsutil 2>/dev/null || echo /usr/lib/google-cloud-sdk/bin/gsutil)")

# Vivado strategies indexed by BATCH_TASK_INDEX (0..7).
# See UG904 and `report_strategy` in Vivado for the full list.
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
git clone --depth=1 --branch "@@GIT_REF@@" "@@GIT_REPO@@" project
cd project

# shellcheck source=/dev/null
source /tools/Xilinx/Vivado/2020.1/settings64.sh
export PATH="${GCP_SDK_BIN}:${PATH}"

# Pass strategies via env vars — patch red_pitaya_vivado_Z20_G2.tcl to read them.
export VIVADO_SYNTH_STRATEGY="${SYNTH_STRAT}"
export VIVADO_IMPL_STRATEGY="${IMPL_STRAT}"

make PRJ=v0.94 MODEL=Z20_G2 prj/v0.94/out/red_pitaya.bit || BUILD_FAILED=1

TAG="task${BATCH_TASK_INDEX}_${SYNTH_STRAT}_${IMPL_STRAT}"
gsutil cp /var/log/build.log             "gs://@@BUCKET@@/@@JOB_NAME@@/${TAG}/"
gsutil -m cp prj/v0.94/out/*.bit "gs://@@BUCKET@@/@@JOB_NAME@@/${TAG}/" 2>/dev/null || true
gsutil -m cp prj/v0.94/out/*.rpt "gs://@@BUCKET@@/@@JOB_NAME@@/${TAG}/" 2>/dev/null || true

WNS=$(grep -Po 'WNS\(ns\)\s*\K-?[\d.]+' prj/v0.94/out/*.rpt 2>/dev/null | head -1 || echo "N/A")
echo "${TAG},${WNS}" | gsutil cp - "gs://@@BUCKET@@/@@JOB_NAME@@/${TAG}/wns.csv"

[ -z "${BUILD_FAILED:-}" ]
