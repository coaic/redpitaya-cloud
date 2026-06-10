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

> **Cost**: ~$0.19/hr while running (n2-standard-4). `stop-desktop.sh` deletes
> the VM entirely — no idle disk charges.

> **Forgotten password**: SSH into the VM and run `sudo passwd packer` to reset it.

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

The only file you need locally is the bitstream to flash to hardware:

```bash
ARTIFACTS=$(cd infra && terraform output -raw artifacts_bucket)
gsutil cp "gs://${ARTIFACTS}/${JOB}/*.bit" ./
```

All diagnostic files (`build.log`, `.rpt` timing reports) stay in GCS —
hand the job name to Claude and it will fetch and analyse them directly.

---

## 4. Check Timing

Give Claude the job name:

```
check timing for job vivado-20260101-120000
```

Claude fetches the timing reports from GCS and tells you whether timing is
met, what the Worst Negative Slack is, and what to change if it isn't.

**Strategy sweep** — after a sweep, ask Claude:

```
compare WNS across all strategies in sweep vivado-sweep-20260101-120000
and recommend which one to use
```

**Interactive timing analysis** — start the remote desktop to inspect critical
paths visually in Vivado:

```bash
./scripts/start-desktop.sh
# open Vivado → File → Open Project
./scripts/stop-desktop.sh   # when done
```

---

## 5. Iterate

If timing fails or the build errors, ask Claude:

```
why did job vivado-20260101-120000 fail?
```

Claude fetches the build log from GCS, identifies the root cause, and suggests
a fix. Then: edit RTL or constraints, push to fork, re-submit from step 2.

See `docs/troubleshooting.md` for common failure patterns.

---

## Using an AI Coding Agent

Claude Code (or any AI coding agent) fits naturally into this workflow. The
`CLAUDE.md` in this repo loads automatically when you run `claude` from the
project root, so the agent already knows the GCP project, bucket names, image
families, build commands, and infrastructure layout — you don't need to explain
any of that.

```bash
# From the repo root
claude
```

### Sonnet — iterative work

Use a fast, cheap model (Sonnet) for the tight edit→build→debug loop:

- **Diagnose a build failure** — paste the error from `build.log` and ask what
  caused it. Claude can read the log directly from GCS:
  ```
  fetch gs://<artifacts-bucket>/<job>/build.log and tell me why the build failed
  (run: cd infra && terraform output artifacts_bucket)
  ```
- **Interpret timing** — paste the Timing Summary section and ask whether timing
  is acceptable, what the critical path is, and what RTL or constraint change
  would help.
- **Edit RTL** — describe what you want to change; Claude can read the source
  files, make the edit, and summarise what it changed and why.
- **Submit and monitor** — ask Claude to submit a build and poll until done;
  it can run the `submit-build.sh` and `gcloud batch` commands for you.
- **Infrastructure changes** — ask Claude to plan and apply Terraform changes;
  it will run `tf.sh dev plan` first and show you the diff before applying.

### Opus — final review

Before a significant build milestone (first timing closure, releasing a
bitstream, changing IP configuration), switch to Opus for a thorough review:

```
/code-review ultra
```

This spawns a multi-agent cloud review of all changed files. Useful for:

- Catching subtle RTL issues (unintended latches, clock-domain crossings,
  reset strategy) before committing to a long build run
- Verifying constraint changes are correct and complete
- Checking that infrastructure changes (IAM, Terraform) are consistent and safe
- Cross-checking that docs still match the implementation after a refactor

Opus reviews cost more and take longer — reserve them for changes where a
missed bug would mean another full build cycle or a broken bitstream.

### Tips

- Claude has no local Vivado installation and cannot run synthesis — it works
  from source files and build logs, not from running Vivado itself.
- All diagnostic files (`build.log`, `.rpt`) live in GCS — Claude fetches them
  directly via `gsutil cat`. You never need to download them locally.
- If a build fails with a cryptic Vivado message, paste the full surrounding
  context (not just the error line) — Vivado errors are often consequences of
  an earlier root cause several lines up.

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
  -var "vivado_installer_gcs=$(cd infra && terraform output -raw installer_bucket_url)/Xilinx_Unified_2020.1_*.tar.gz" \
  vivado-image.pkr.hcl
```

New image joins the `vivado-2020-1` family immediately.

## Monitoring Costs

```bash
gcloud batch jobs list --location=australia-southeast1 --project=redpitaya-fpga-builds
gsutil du -sh "gs://$(cd infra && terraform output -raw artifacts_bucket)/"
```

The budget alert (if configured in `dev.yml`) emails you at 50%, 90%, and 100%
of the monthly limit.

## Linting Scripts

Before pushing changes to any `scripts/` file, run:

```bash
make lint
```

This runs `shellcheck` over all shell scripts and reports any issues. Install
shellcheck with `brew install shellcheck` if you don't have it.
