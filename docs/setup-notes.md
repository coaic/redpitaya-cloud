# Setup Notes — GCP Cloud Build Infrastructure

Lessons and gotchas encountered standing up the ephemeral Vivado build pipeline
from scratch on an Apple Silicon Mac. Written so the next person (or next time)
doesn't hit the same walls.

## Prerequisites

```bash
brew tap hashicorp/tap
brew install google-cloud-sdk hashicorp/tap/terraform hashicorp/tap/packer yq jq
```

**Note:** `terraform` and `packer` both moved to `hashicorp/tap` after the BSL
licence change — they are no longer in the core Homebrew formula list.
`google-cloud-sdk` is now the cask `google-cloud-sdk` (not a formula).

## GCP Account Setup

### Billing account currency
The `google_billing_budget` Terraform resource requires the currency to match
the billing account's currency. A personal Australian account is billed in AUD.
Specifying `USD` returns a generic `400: Request contains an invalid argument`
with no further detail.

Fix: set `currency_code: AUD` in `infra/environments/dev.yml`.

### Billing Budgets API needs a quota project
The Billing Budgets API cannot be called via Application Default Credentials
without a quota project set. Symptom: `403 SERVICE_DISABLED` with consumer
`projects/764086051850` (Google's internal ADC project, not yours).

Fix:
```bash
gcloud auth application-default set-quota-project redpitaya-fpga-builds
```

This requires `cloudresourcemanager.googleapis.com` and `iam.googleapis.com`
to be enabled on the project first — both are bootstrapped via `bootstrap.sh`
before `terraform init`.

### Terraform state bootstrap (chicken-and-egg)
The GCS bucket used as the Terraform backend cannot be managed by the same
Terraform workspace. It must exist before `terraform init`.

Fix: `scripts/bootstrap.sh` creates the tfstate bucket and enables prerequisite
APIs via `gcloud` before Terraform is ever run. Run order:

```
scripts/bootstrap.sh dev
cd infra && ./tf.sh dev init
./tf.sh dev plan && ./tf.sh dev apply
```

### Budget project filter needs project number, not project ID
`google_billing_budget.budget_filter.projects` requires the numeric project
number (`projects/457917127807`), not the string project ID
(`projects/redpitaya-fpga-builds`). Using the string ID returns `400: invalid
argument`.

Fix: the `budget` module uses a `google_project` data source to look up the
number dynamically.

## Packer Image Bake

### Ubuntu 20.04 LTS removed from GCP public catalog
`ubuntu-2004-lts` in `ubuntu-os-cloud` was removed (EOL April 2025).

Fix: use `ubuntu-pro-2004-lts` from `ubuntu-os-pro-cloud` (extended security
support, no additional cost on GCP).

```hcl
source_image_family         = "ubuntu-pro-2004-lts"
source_image_project_id     = ["ubuntu-os-pro-cloud"]
```

### `google-cloud-cli` not in default Ubuntu apt repos
The package `google-cloud-cli` requires Google's apt repository to be added
first. GCP-managed Ubuntu images already have `gsutil` pre-installed.

Fix: remove `google-cloud-cli` from the apt package list entirely.

### `build-essential` dependency conflict on Ubuntu Pro
`build-essential` conflicts with ESM-patched versions of `gcc`/`g++`/`libc6-dev`
on Ubuntu Pro 20.04. Vivado includes its own compiler toolchain so
`build-essential` is not needed.

Fix: remove `build-essential` and `python3-pip` from the apt install list.
Minimal required packages:
```
libtinfo5 libncurses5 libx11-6 libxrender1 libxtst6 libxi6
libxrandr2 libfreetype6 libfontconfig1 git make
```

### apt lock held on first boot (Ubuntu Pro)
Ubuntu Pro's `ubuntu-advantage-tools` runs a Python3 process on first boot
that holds the apt lock. Packer connects via SSH almost immediately and
`apt-get update` fails with `Could not get lock /var/lib/apt/lists/lock`.

Fix: add a wait loop at the start of the first provisioner:
```bash
while sudo fuser /var/lib/apt/lists/lock /var/lib/dpkg/lock \
      /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
  echo "Waiting for apt lock..."; sleep 5
done
```

### Vivado install_config.txt Modules field — device families only
For the Unified Installer, the `Modules` field in the silent install config
only accepts device family names. Optional tools (`SDK`, `Vitis`, `DocNav`)
are not valid values and return:
`ERROR: The value specified in the configuration file for Modules (...) is not valid.`

Fix: specify only the device families you need:
```
Modules=Zynq-7000:1
```

### Vivado version is hard-pinned to 2020.1
The Red Pitaya Gen 2 gateware repo (`prj/v0.94/ip/systemZ20_G2.tcl`) contains:
```tcl
set scripts_vivado_version 2020.1
```
Vivado's TCL engine checks this at runtime and errors if the version doesn't
match. The 2021.1 unified installer (downloaded first by mistake) cannot be
used.

## Red Pitaya Build Target

The Makefile does not have a `make fpga` target. The correct invocation for a
gateware-only build (no FSBL or device tree, which require `xsct`/SDK):

```bash
make PRJ=v0.94 MODEL=Z20_G2 prj/v0.94/out/red_pitaya.bit
```

Output bitstream: `prj/v0.94/out/red_pitaya.bit`
Timing reports: `prj/v0.94/out/*.rpt`

The `all` target additionally builds FSBL and device tree via `xsct`, which
requires the Vitis/SDK component — not installed in the WebPACK image.
