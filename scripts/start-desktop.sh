#!/usr/bin/env bash
# start-desktop.sh — create (if needed) and start the Vivado remote desktop VM,
# then open an IAP RDP tunnel.
#
# The VM is created fresh from the vivado-redpitaya image each session and
# deleted by stop-desktop.sh — no idle disk cost.
#
# Usage: ./scripts/start-desktop.sh
#
# Prerequisites:
#   - gcloud auth login
#   - Microsoft Remote Desktop installed (Mac App Store, free)
#
# After running: open Microsoft Remote Desktop → New PC → localhost:3389
#   Username: packer   Password: set via 'sudo passwd packer' on first login

set -euo pipefail

PROJECT="${GCP_PROJECT:-redpitaya-fpga-builds}"
ZONE="${GCP_ZONE:-australia-southeast1-a}"
REGION="${GCP_REGION:-australia-southeast1}"
INSTANCE="vivado-desktop"

# Create VM if it doesn't exist
if ! gcloud compute instances describe "${INSTANCE}" \
     --zone="${ZONE}" --project="${PROJECT}" &>/dev/null; then
  echo "Creating ${INSTANCE} from vivado-redpitaya image..."
  gcloud compute instances create "${INSTANCE}" \
    --project="${PROJECT}" \
    --zone="${ZONE}" \
    --machine-type=n2-standard-4 \
    --image-family=vivado-redpitaya \
    --image-project="${PROJECT}" \
    --boot-disk-size=200GB \
    --boot-disk-type=pd-balanced \
    --no-address \
    --tags=vivado-desktop \
    --metadata=enable-oslogin=TRUE
  echo "VM created."
else
  echo "Starting ${INSTANCE}..."
  gcloud compute instances start "${INSTANCE}" \
    --zone="${ZONE}" --project="${PROJECT}"
fi

echo ""
echo "Opening IAP tunnel on localhost:3389..."
echo "Connect Microsoft Remote Desktop to localhost:3389 (username: packer)"
echo "Run ./scripts/stop-desktop.sh when done to delete the VM and stop all charges."
echo ""

gcloud compute start-iap-tunnel "${INSTANCE}" 3389 \
  --local-host-port=localhost:3389 \
  --zone="${ZONE}" \
  --project="${PROJECT}"
