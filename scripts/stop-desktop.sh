#!/usr/bin/env bash
# stop-desktop.sh — delete the Vivado desktop VM entirely.
# The VM is recreated from the image next time start-desktop.sh runs.
# This eliminates all ongoing costs (no idle disk charges).

set -euo pipefail

PROJECT="${GCP_PROJECT:-redpitaya-fpga-builds}"
ZONE="${GCP_ZONE:-australia-southeast1-a}"

if gcloud compute instances describe vivado-desktop \
   --zone="${ZONE}" --project="${PROJECT}" &>/dev/null; then
  gcloud compute instances delete vivado-desktop \
    --zone="${ZONE}" --project="${PROJECT}" --quiet
  echo "vivado-desktop deleted. No ongoing charges."
else
  echo "vivado-desktop does not exist — nothing to do."
fi
