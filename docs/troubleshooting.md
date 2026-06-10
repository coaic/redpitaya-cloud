# Troubleshooting

## Diagnosing with Claude

The fastest way to diagnose a failure is to use Claude Code directly in this repo.
`CLAUDE.md` loads automatically as project context, so Claude already knows the
infrastructure layout, GCP project, bucket names, and expected behaviour.

```bash
# From the repo root
claude
```

Then describe what failed and paste any error output. Claude can read the Terraform
state, inspect GCP resources, check logs, and suggest fixes without you having to
explain the architecture from scratch.

For one-off questions without a full session, paste this into Claude:

> I'm working on redpitaya-cloud — GCP Cloud Batch FPGA builds for Red Pitaya Gen 2
> using Vivado 2020.1. Here is the error I hit: [paste error]. Relevant context:
> project `YOUR_PROJECT_ID`, installer bucket `YOUR_INSTALLER_BUCKET`,
> artifacts bucket `YOUR_ARTIFACTS_BUCKET`, service account
> `fpga-builder@YOUR_PROJECT_ID.iam.gserviceaccount.com`,
> image family `vivado-2020-1`. Help me diagnose this.
>
> (Run `cd infra && terraform output` to get the exact bucket names for your deployment.)

---

## IAM Requirements

All permissions are managed by Terraform (`infra/modules/iam/`). After `tf apply`
the following bindings exist:

| Principal | Resource | Role | Purpose |
|---|---|---|---|
| `fpga-builder` SA | Project | `roles/batch.agentReporter` | Batch agent heartbeat — without this jobs hang |
| `fpga-builder` SA | Project | `roles/logging.logWriter` | Write build logs to Cloud Logging |
| `fpga-builder` SA | `*-fpga-artifacts` bucket | `roles/storage.objectAdmin` | Upload bitstreams and build logs |
| `fpga-builder` SA | `*-fpga-installer` bucket | `roles/storage.objectViewer` | Read Vivado installer during Packer bake |
| Submitter (your email) | Project | `roles/batch.jobsEditor` | Submit and cancel Cloud Batch jobs |
| Submitter (your email) | `fpga-builder` SA | `roles/iam.serviceAccountUser` | Run jobs as the builder SA |
| Submitter (your email) | `*-fpga-artifacts` bucket | `roles/storage.objectViewer` | Fetch bitstreams after build |

The Packer bake VM runs as `fpga-builder` (set via `service_account_email` in
`packer/vivado-image.pkr.hcl`). If you see a 403 during the installer download
step, the installer bucket IAM binding is missing — run `tf apply` to fix it.

---

## Common Failures

### Packer: `403 AccessDenied` on installer download

```
AccessDeniedException: 403 ... does not have storage.objects.get access
```

**Cause:** `fpga-builder` SA lacks `storage.objectViewer` on the installer bucket,
or Packer is using the default compute SA instead of `fpga-builder`.

**Fix:** Run `cd infra && ./tf.sh dev apply`. The IAM module grants this binding.
If still failing, check `service_account_email` is set in
`packer/vivado-image.pkr.hcl`.

---

### Packer: build times out or SSH never connects

**Cause:** Network or firewall issue preventing Packer SSH access to the bake VM.

**Fix:** Confirm Private Google Access is enabled on the subnet (Terraform
networking module handles this). The Packer bake VM in this project gets an
external IP by default, so direct SSH should work without `use_iap`.

---

### Cloud Batch: job FAILED immediately (state never RUNNING)

Check the status events:

```bash
gcloud batch jobs describe JOB_NAME \
  --location=australia-southeast1 --project=redpitaya-fpga-builds \
  --format='yaml(status.statusEvents)'
```

Common causes:
- **Boot disk smaller than image** — `sizeGb` in `submit-build.sh` must be ≥ 200 GB
- **Quota exceeded** — check `gcloud compute regions describe australia-southeast1`
- **Image family not found** — Packer bake hasn't completed yet

---

### Cloud Batch: job RUNNING but build fails

Give Claude the job name and ask it to fetch the `build.log` from GCS:

```
why did job vivado-20260101-120000 fail?
```

Claude reads `gs://ARTIFACTS_BUCKET/JOB_NAME/build.log` (run `cd infra && terraform output artifacts_bucket`)
directly and diagnoses the error. (The log is uploaded even on failure via the
`trap` in `submit-build.sh`.)

For real-time streaming before the job exits, tail the Cloud Logging stream:

```bash
gcloud logging read \
  'resource.type="batch.googleapis.com/Job" AND labels."batch.googleapis.com/job_uid"="JOB_NAME"' \
  --project=redpitaya-fpga-builds --limit=200 --order=asc \
  --format='value(textPayload)'
```

---

## Useful Diagnostic Commands

```bash
# List recent jobs and their states
gcloud batch jobs list --location=australia-southeast1 --project=redpitaya-fpga-builds

# Full status events for a job
gcloud batch jobs describe JOB_NAME \
  --location=australia-southeast1 --project=redpitaya-fpga-builds \
  --format='yaml(status)'

# List images in the vivado-2020-1 family
gcloud compute images list --project=redpitaya-fpga-builds \
  --no-standard-images --filter="family=vivado-2020-1"

# Check IAM bindings on the installer bucket
gsutil iam get $(cd infra && terraform output -raw installer_bucket_url)

# Check service account exists
gcloud iam service-accounts describe \
  fpga-builder@redpitaya-fpga-builds.iam.gserviceaccount.com \
  --project=redpitaya-fpga-builds
```
