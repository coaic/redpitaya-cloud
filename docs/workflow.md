# Day-to-Day Workflow

## Single Build

Submit one build from a git branch:

```bash
export GCP_PROJECT=your-project-id
# optionally override region
export GCP_REGION=australia-southeast1

./scripts/submit-build.sh git@github.com:org/repo.git main
./scripts/submit-build.sh git@github.com:org/repo.git feature/my-branch
```

The job runs as a SPOT VM, uploads `out/*.bit` and `build.log` to GCS, then
terminates. Estimated cost: ~$0.10–$0.30 per build on n2-custom-4-32768 SPOT.

## Strategy Sweep (Parallel Timing Exploration)

Run 8 Vivado synth/impl strategy combinations in parallel to find the best
timing closure:

```bash
./scripts/submit-sweep.sh git@github.com:org/repo.git main
```

When complete, compare Worst Negative Slack across strategies:

```bash
gsutil cat "gs://${GCP_PROJECT}-fpga-artifacts/vivado-sweep-<DATE>/*/wns.csv"
```

Pick the strategy with the best (least negative) WNS, then wire that strategy
permanently into your project Makefile.

## Retrieving Artifacts

```bash
BUCKET="${GCP_PROJECT}-fpga-artifacts"
JOB="vivado-20240601-120000"  # from submit output

# List all artifacts for a job
gsutil ls "gs://${BUCKET}/${JOB}/"

# Download bitstream
gsutil cp "gs://${BUCKET}/${JOB}/*.bit" ./

# View build log
gsutil cat "gs://${BUCKET}/${JOB}/build.log"
```

## Infrastructure Changes

When you need to change Terraform config (e.g., retention period, budget):

```bash
cd infra
# edit environments/dev.yml
./tf.sh dev plan    # review changes
./tf.sh dev apply
```

## Updating the Vivado Image

Only needed when changing Vivado version or adding system packages:

```bash
cd packer
packer build \
  -var project_id=${GCP_PROJECT} \
  -var vivado_installer_gcs=gs://${BUCKET}/bootstrap/installer.tar.gz \
  vivado-image.pkr.hcl
```

New image joins the `vivado-redpitaya` family immediately. Old images are kept
by GCP (delete manually if space is a concern).

## Monitoring Costs

```bash
# List recent Batch jobs and their states
gcloud batch jobs list --location=australia-southeast1

# GCS usage
gsutil du -sh "gs://${GCP_PROJECT}-fpga-artifacts/"
```

The budget alert (if configured in dev.yml) will email you at 50%, 90%, and
100% of the monthly limit.

## Future: GitHub Actions Orchestration

The submit scripts are plain shell — they can be called from a GitHub Actions
workflow without changes:

```yaml
# .github/workflows/build-fpga.yml (future)
- name: Submit FPGA build
  env:
    GCP_PROJECT: ${{ secrets.GCP_PROJECT }}
  run: ./scripts/submit-build.sh ${{ github.repository }} ${{ github.sha }}
```

Workload Identity Federation is the recommended auth path (no long-lived keys).
