# RedPityaGen2 — FPGA Build Infrastructure

Cloud-based build system for Red Pitaya Gen 2 gateware. Vivado 2020.1 has no Apple Silicon support, so all synthesis / place-and-route runs on ephemeral x86-64 SPOT VMs in Google Cloud Batch.

## Project Structure

```
RedPityaGen2/
├── infra/                        # Terraform infrastructure
│   ├── modules/
│   │   ├── apis/                 # GCP API enablement
│   │   ├── storage/              # GCS artifact bucket
│   │   ├── iam/                  # Service accounts + IAM bindings
│   │   └── budget/               # Billing budget alert
│   ├── environments/
│   │   └── dev.yml               # Per-environment config (YAML)
│   ├── main.tf                   # Root module — calls sub-modules
│   ├── variables.tf
│   ├── outputs.tf
│   └── tf.sh                     # YAML→Terraform wrapper (needs yq)
├── packer/
│   ├── vivado-image.pkr.hcl      # Bakes GCP image with Vivado 2020.1
│   └── install_config.txt        # Vivado silent install config (WebPACK)
├── scripts/
│   ├── submit-build.sh           # Submit a single Cloud Batch build job
│   └── submit-sweep.sh           # Submit 8 parallel strategy-sweep jobs
├── docs/
│   ├── architecture.md
│   ├── getting-started.md
│   └── workflow.md
└── files/                        # Original prototype files (reference)
```

## Design Principles

- **Ephemeral compute**: Cloud Batch SPOT VMs spin up per job, terminate on completion. No always-on VMs.
- **Persistent artifacts**: GCS bucket stores bitstreams and logs. 30-day lifecycle auto-deletes old builds.
- **Semi-persistent image**: Vivado is baked into a GCP image once with Packer. Reused by every job.
- **Serverless**: No Compute Engine instances, no GKE, no Cloud Run — just Batch + GCS.
- **Local orchestration**: Shell scripts run from the developer's machine. GitHub Actions is the future path.

## Terraform Pattern

- Modules in `infra/modules/<name>/` — each has `main.tf`, `variables.tf`, and optionally `outputs.tf`.
- Per-environment config in `infra/environments/<env>.yml` (YAML, not `.tfvars`).
- `tf.sh` converts YAML to JSON and passes it to terraform via `-var-file`.
- Never add flat single-file Terraform here — always use the module structure.

```bash
cd infra
terraform init
./tf.sh dev plan
./tf.sh dev apply
```

## Vivado Target

| | |
|---|---|
| Edition | WebPACK (free, no licence) |
| Device | Zynq-7020 (xc7z020clg484-1) |
| Version | 2020.1 |
| Build command | `make fpga` (in project repo root) |
| Output artefacts | `out/*.bit` |

## Key Environment Variables (scripts)

| Variable | Default | Purpose |
|---|---|---|
| `GCP_PROJECT` | (required) | GCP project ID |
| `GCP_REGION` | `australia-southeast1` | Region for Batch jobs |

## Quick Reference

```bash
# Apply infra (first time or after config change)
cd infra && ./tf.sh dev apply

# Bake Vivado image (once, ~45 min)
cd packer && packer build -var project_id=... -var vivado_installer_gcs=gs://... vivado-image.pkr.hcl

# Single build
export GCP_PROJECT=my-project
./scripts/submit-build.sh git@github.com:org/repo.git main

# 8-way strategy sweep
./scripts/submit-sweep.sh git@github.com:org/repo.git main

# Check WNS across sweep strategies
gsutil cat "gs://${GCP_PROJECT}-fpga-artifacts/<job-name>/*/wns.csv"
```

## Docs

- [Architecture](docs/architecture.md) — system design, component diagram, design decisions
- [Getting Started](docs/getting-started.md) — first-time setup from scratch
- [Workflow](docs/workflow.md) — day-to-day build submission, artifact retrieval, cost monitoring
