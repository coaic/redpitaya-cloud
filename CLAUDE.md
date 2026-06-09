# RedPityaGen2 — FPGA Build Infrastructure

Cloud build infrastructure for [Red Pitaya Gen 2](https://github.com/RedPitaya/RedPitaya-FPGA)
gateware. Vivado 2020.1 has no Apple Silicon support, so all synthesis / place-and-route
runs on ephemeral x86-64 SPOT VMs in Google Cloud Batch.

Also provides a remote Vivado GUI desktop via XRDP on a persistent GCP VM for IP
configuration and RTL editing without a local x86-64 machine.

## Project Structure

```
RedPityaGen2/
├── infra/                        # Terraform infrastructure (all applied)
│   ├── modules/
│   │   ├── apis/                 # GCP API enablement
│   │   ├── storage/              # GCS artifact bucket
│   │   ├── iam/                  # Service accounts + IAM bindings
│   │   ├── networking/           # VPC, Private Google Access, Cloud NAT
│   │   └── budget/               # Billing budget alert
│   ├── environments/
│   │   └── dev.yml               # Per-environment config (YAML)
│   ├── main.tf                   # Root module — calls sub-modules
│   ├── variables.tf
│   ├── outputs.tf
│   └── tf.sh                     # YAML→Terraform wrapper (needs yq)
├── packer/
│   ├── vivado-image.pkr.hcl      # Bakes GCP image: Vivado 2020.1 + XFCE + XRDP
│   └── install_config.txt        # Vivado silent install config (WebPACK, Zynq-7000)
├── scripts/
│   ├── bootstrap.sh              # One-time: create Terraform state bucket
│   ├── submit-build.sh           # Submit a Cloud Batch synthesis job
│   ├── submit-sweep.sh           # Submit 8 parallel strategy-sweep jobs
│   ├── start-desktop.sh          # Start vivado-desktop VM + open IAP RDP tunnel
│   └── stop-desktop.sh           # Stop vivado-desktop VM (stops billing)
└── docs/
    ├── architecture.md           # System design, component diagram
    ├── getting-started.md        # First-time setup from scratch
    ├── workflow.md               # Day-to-day build submission and monitoring
    ├── setup-notes.md            # Gotchas and lessons learned
    ├── vivado-remote-desktop-plan.md  # Remote desktop design + PoC results
    └── status.md                 # Current state — read this first
```

## GCP Resources (all provisioned)

| Resource | Name | Notes |
|---|---|---|
| Project | `redpitaya-fpga-builds` | Billing account `01585C-551A25-735AA8` |
| Artifacts bucket | `redpitaya-fpga-builds-fpga-artifacts` | 30-day lifecycle |
| Installer bucket | `redpitaya-fpga-builds-fpga-installer` | Vivado 2020.1 installer |
| Terraform state | `redpitaya-fpga-builds-fpga-tfstate` | Versioned |
| Image family | `vivado-redpitaya` | Ubuntu 20.04 Pro + Vivado 2020.1 + XFCE + XRDP |
| Desktop VM | `vivado-desktop` | n2-standard-4, 200 GB, australia-southeast1-a |
| Service account | `fpga-builder@redpitaya-fpga-builds.iam.gserviceaccount.com` | No key file |
| IAP firewall | `allow-rdp-iap` | Allows IAP tunnel to port 3389 on `vivado-desktop` tag |

## Vivado Target

| | |
|---|---|
| Edition | WebPACK (free, no licence) |
| Device | Zynq-7020 (`xc7z020clg484-1`) |
| Version | 2020.1 (hard-pinned in `systemZ20_G2.tcl`) |
| Source repo | `github.com/RedPitaya/RedPitaya-FPGA` |
| Branch | `master` (all Release-20xx.x branches also use Vivado 2020.1) |
| Build command | `make PRJ=v0.94 MODEL=Z20_G2 prj/v0.94/out/red_pitaya.bit` |
| Output | `prj/v0.94/out/red_pitaya.bit` |

## Quick Reference

```bash
export GCP_PROJECT=redpitaya-fpga-builds

# Submit a batch synthesis build
./scripts/submit-build.sh git@github.com:RedPitaya/RedPitaya-FPGA.git master

# 8-way strategy sweep
./scripts/submit-sweep.sh git@github.com:RedPitaya/RedPitaya-FPGA.git master

# Fetch bitstream when done
gsutil cp "gs://redpitaya-fpga-builds-fpga-artifacts/<job-name>/*.bit" ./

# Start remote Vivado GUI desktop
./scripts/start-desktop.sh
# → open Microsoft Remote Desktop → localhost:3389 → username: packer

# Stop desktop VM when done
./scripts/stop-desktop.sh

# Terraform (if infra changes needed)
cd infra && ./tf.sh dev plan && ./tf.sh dev apply
```

## Design Principles

- **Ephemeral compute**: Cloud Batch SPOT VMs spin up per job, terminate on completion.
- **Persistent artifacts**: GCS stores bitstreams and logs with 30-day lifecycle.
- **No secrets in repo**: No service account keys. VMs authenticate via GCE metadata.
- **Local orchestration**: Shell scripts run from the developer's Mac.

## Docs

- [Status](docs/status.md) — current state of all infrastructure and next steps
- [Getting Started](docs/getting-started.md) — first-time setup from scratch
- [Workflow](docs/workflow.md) — day-to-day build submission and monitoring
- [Remote Desktop Plan](docs/vivado-remote-desktop-plan.md) — design and PoC results
- [Architecture](docs/architecture.md) — system design and component diagram
