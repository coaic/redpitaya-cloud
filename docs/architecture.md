# Architecture

## Overview

Red Pitaya Gen 2 gateware is built using Xilinx Vivado 2020.1, targeting the Zynq-7020 SoC. Vivado has no Apple Silicon support, so all synthesis and place-and-route runs on ephemeral x86-64 VMs in Google Cloud.

The design is intentionally **serverless / ephemeral**:
- No always-on VMs. Every build spins up a fresh SPOT instance and terminates on completion.
- GCS is the only persistent resource between builds (artifacts, logs).
- The Vivado image (baked once with Packer) is semi-persistent — it lives in GCP as a custom image family and is reused by every job.

## Components

```
┌──────────────────────────────────────────────────────┐
│  Local (Apple Silicon)                               │
│  ┌────────────┐  ┌───────────┐  ┌─────────────────┐ │
│  │  tf.sh     │  │ submit-   │  │  submit-sweep.sh│ │
│  │  (infra)   │  │ build.sh  │  │  (strategy opt) │ │
│  └─────┬──────┘  └─────┬─────┘  └────────┬────────┘ │
└────────┼───────────────┼─────────────────┼──────────┘
         │               │                 │
         ▼               ▼                 ▼
┌──────────────────────────────────────────────────────┐
│  Google Cloud                                        │
│                                                      │
│  ┌─────────────┐    ┌──────────────────────────────┐ │
│  │  Terraform  │    │  Cloud Batch                 │ │
│  │  (infra)    │    │  ┌──────┐ ┌──────┐ ┌──────┐  │ │
│  │  - GCS      │    │  │ VM 0 │ │ VM 1 │ │ VM N │  │ │
│  │  - IAM      │    │  │SPOT  │ │SPOT  │ │SPOT  │  │ │
│  │  - APIs     │    │  └──┬───┘ └──┬───┘ └──┬───┘  │ │
│  │  - Budget   │    └─────┼────────┼─────────┼──────┘ │
│  └─────────────┘          │        │         │       │
│                           ▼        ▼         ▼       │
│  ┌───────────────────────────────────────────────┐   │
│  │  GCS: <project>-fpga-artifacts/               │   │
│  │    <job-name>/*.bit  (bitstreams)             │   │
│  │    <job-name>/build.log                       │   │
│  │    <job-name>/*/wns.csv  (sweep timing)       │   │
│  └───────────────────────────────────────────────┘   │
│                                                      │
│  ┌───────────────────────────────────────────────┐   │
│  │  Custom GCP Image: vivado-redpitaya (family)  │   │
│  │  Ubuntu 20.04 + Vivado 2020.1 WebPACK        │   │
│  │  (baked once with Packer, reused every job)  │   │
│  └───────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────┘
```

## Key Design Decisions

| Decision | Rationale |
|---|---|
| Cloud Batch (not Compute Engine) | Fully managed job scheduling; VMs auto-terminate when job finishes |
| SPOT instances | ~70–80% cheaper than on-demand; build failures are retried (maxRetryCount: 2) |
| Custom Packer image | Vivado is ~50 GB; baking it into an image avoids a 45-min install per job |
| No external IP on build VMs | VMs access GCS via Private Google Access; reduces attack surface |
| YAML environment files | Decouples config from code; enables dev/prod without duplicating Terraform |
| GCS lifecycle rules | Artifacts auto-expire after N days; prevents runaway storage costs |

## Resource Lifecycle

```
One-time setup:
  packer build  →  Custom image (GCP Image Family)
  tf.sh apply   →  GCS bucket + IAM + APIs + optional budget

Per build:
  submit-build.sh  →  Batch job created
                   →  SPOT VM boots (custom image)
                   →  git clone + make fpga
                   →  gsutil cp artifacts → GCS
                   →  VM terminates
```

## Vivado Target

- **Edition**: WebPACK (free, no licence file needed)
- **Device**: Zynq-7020 (xc7z020clg484-1) — Red Pitaya Gen 2 part
- **Version**: 2020.1 (last version with Zynq-7000 WebPACK support before Xilinx UG changes)
- **Build trigger**: `make fpga` in the project repo root
- **Outputs expected at**: `out/*.bit`
