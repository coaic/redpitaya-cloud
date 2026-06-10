# Developer Workflow

The typical loop: edit gateware → submit cloud build → check timing → repeat.

---

## 1. Edit Gateware

### Option A — Edit locally, push to fork

Edit RTL files in your local Red Pitaya FPGA checkout. The source lives under
`prj/v0.94/` and `rtl/`:

```bash
cd ~/Projects/Github/coaic/RedPitaya-FPGA   # or wherever you cloned it
# edit RTL files
git add -p
git commit -m "describe change"
git push origin master   # or your branch
```

### Option B — Edit in Vivado GUI on the remote desktop

For IP reconfiguration or timing-driven changes that need the Vivado GUI:

```bash
./scripts/start-desktop.sh
```

Open Microsoft Remote Desktop → `localhost:3389` → username `packer`.
Vivado is pre-installed. Make changes, export any modified IP XCI files back to
your local checkout, then push.

```bash
./scripts/stop-desktop.sh   # deletes VM when done — no idle charges
```

---

## 2. Submit a Cloud Build

```bash
export GCP_PROJECT=redpitaya-fpga-builds

# Single build from a branch
./scripts/submit-build.sh https://github.com/coaic/RedPitaya-FPGA.git master

# 8-way strategy sweep (parallel timing exploration)
./scripts/submit-sweep.sh https://github.com/coaic/RedPitaya-FPGA.git master
```

The job prints a job name and GCS artifact path. Build takes ~8–10 minutes on
a SPOT VM.

Poll until done:

```bash
JOB=vivado-20260101-120000   # from submit output
gcloud batch jobs describe ${JOB} \
  --location=australia-southeast1 --project=redpitaya-fpga-builds \
  --format='value(status.state)'
```

---

## 3. Retrieve Artifacts

```bash
BUCKET=redpitaya-fpga-builds-fpga-artifacts

# List outputs
gsutil ls "gs://${BUCKET}/${JOB}/"

# Download bitstream
gsutil cp "gs://${BUCKET}/${JOB}/*.bit" ./

# View build log (includes timing summary)
gsutil cat "gs://${BUCKET}/${JOB}/build.log"
```

---

## 4. Check Timing

**Quick check** — scan the build log for Worst Negative Slack:

```bash
gsutil cat "gs://${BUCKET}/${JOB}/build.log" | grep -E "WNS|Timing"
```

A positive WNS means timing is met. Negative means a timing violation — the
bitstream may be unreliable at the target clock frequency.

**Strategy sweep results** — compare WNS across all 8 strategies:

```bash
gsutil cat "gs://${BUCKET}/vivado-sweep-<DATE>/*/wns.csv"
```

Pick the strategy with the best (least negative or most positive) WNS and wire
it permanently into the project Makefile.

**Interactive timing analysis** — start the remote desktop and open the
project in Vivado to inspect the Timing Summary report or critical paths:

```bash
./scripts/start-desktop.sh
# open Vivado → File → Open Project → navigate to a local copy of the build
./scripts/stop-desktop.sh   # when done
```

---

## 5. Iterate

If timing fails or the build errors:

1. Check `build.log` for the first `ERROR:` line
2. Fix in RTL or adjust constraints
3. Push to fork and re-submit from step 2

See `docs/troubleshooting.md` for common failure patterns.

---

## Infrastructure Changes

When you need to change Terraform config (retention period, budget, etc.):

```bash
cd infra
# edit environments/dev.yml
./tf.sh dev plan
./tf.sh dev apply
```

## Updating the Vivado Image

Only needed when changing Vivado version or adding system packages:

```bash
cd packer
packer build \
  -var project_id=${GCP_PROJECT} \
  -var vivado_installer_gcs=gs://redpitaya-fpga-builds-fpga-installer/Xilinx_Unified_2020.1_*.tar.gz \
  vivado-image.pkr.hcl
```

New image joins the `vivado-2020-1` family immediately.

## Monitoring Costs

```bash
gcloud batch jobs list --location=australia-southeast1 --project=redpitaya-fpga-builds
gsutil du -sh "gs://redpitaya-fpga-builds-fpga-artifacts/"
```

The budget alert (if configured in `dev.yml`) emails you at 50%, 90%, and 100%
of the monthly limit.
