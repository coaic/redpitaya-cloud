#!/bin/bash
# build-task.sh — runs on the Cloud Batch VM.
# @@MARKER@@ values are substituted by submit-build.sh at submission time.
# Do not run directly.
set -e
exec > >(tee /var/log/build.log) 2>&1

export HOME=/root

gcs_upload() {
  local src="$1" dst="$2"
  local token object
  token=$(curl -sf \
    -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
  object=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "${dst}")
  curl -sf -X POST \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/octet-stream" \
    --data-binary "@${src}" \
    "https://storage.googleapis.com/upload/storage/v1/b/@@BUCKET@@/o?uploadType=media&name=${object}" \
    > /dev/null \
    && echo "Uploaded ${src} -> gs://@@BUCKET@@/${dst}" \
    || echo "WARNING: upload failed for ${src}"
}

echo "Batch task: ${BATCH_TASK_INDEX} of ${BATCH_TASK_COUNT}"

cd /tmp
rm -rf project
git clone --depth=1 --branch "@@GIT_REF@@" "@@GIT_REPO@@" project
cd project

# shellcheck source=/dev/null
source /tools/Xilinx/Vivado/2020.1/settings64.sh

make PRJ=v0.94 MODEL=Z20_G2 prj/v0.94/out/red_pitaya.bit || BUILD_FAILED=1

gcs_upload /var/log/build.log "@@JOB_NAME@@/build.log"
for f in prj/v0.94/out/*.bit prj/v0.94/out/*.rpt; do
  [ -f "$f" ] && gcs_upload "$f" "@@JOB_NAME@@/$(basename "$f")"
done

[ -z "${BUILD_FAILED:-}" ]
