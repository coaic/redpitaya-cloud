# Project Status

Last updated: 2026-06-09

## Infrastructure — All Provisioned

| Component | Status | Notes |
|---|---|---|
| GCP project `redpitaya-fpga-builds` | ✅ Live | Billing linked |
| Terraform infrastructure | ✅ Applied | VPC, GCS buckets, IAM, NAT, budget |
| Vivado installer in GCS | ✅ Uploaded | `gs://redpitaya-fpga-builds-fpga-installer/Xilinx_Unified_2020.1_0602_1208.tar.gz` |
| Packer image `vivado-redpitaya` | ✅ Ready | `vivado-2020-1-1780984785` — Vivado 2020.1 + XFCE + XRDP |
| Cloud Batch pipeline | ✅ Working | Tested against placeholder repo |
| IAP firewall rule | ✅ Applied | `allow-rdp-iap` → port 3389 |
| `vivado-desktop` VM | ✅ On-demand | Created/deleted by scripts — no idle cost |
| Remote desktop PoC | ✅ Validated | XRDP + XFCE responsive, Vivado GUI usable |

## Next Steps

### 1. Test batch build against actual Red Pitaya repo

This is the immediate next step — not yet done:

```bash
export GCP_PROJECT=redpitaya-fpga-builds
./scripts/submit-build.sh git@github.com:RedPitaya/RedPitaya-FPGA.git master
```

Expected: Vivado 2020.1 builds `prj/v0.94/out/red_pitaya.bit` for Zynq-7020 Gen 2.
Fetch result: `gsutil cp "gs://redpitaya-fpga-builds-fpga-artifacts/<job-name>/*.bit" ./`

### 2. Merge `feat/vivado-remote-desktop` → `main`

The remote desktop work is on `feat/vivado-remote-desktop`. Once the batch build
validates, merge to main.

### 3. Clean up stale branches

- `fix/purge-billing-account-from-history` — pending review/merge or delete
- `feat/cloud-build-infrastructure` — superseded by main, can be deleted

## Key Facts to Remember

**Vivado version**: 2020.1 is hard-pinned in `prj/v0.94/ip/systemZ20_G2.tcl`. All
`Release-20xx.x` branches in `RedPitaya/RedPitaya-FPGA` also use 2020.1 — the branch
naming refers to the Red Pitaya software release, not the Vivado version.

**Desktop VM cost**: ~$0.19/hr while running, zero when not in use.
`start-desktop.sh` creates the VM fresh from the image each session.
`stop-desktop.sh` deletes it entirely — no idle disk charges.

**Desktop login**: username `packer`, password set manually via `sudo passwd packer`
after first SSH in. If password is forgotten, SSH in again and reset it.

**Billing account ID**: stored in `infra/environments/dev.local.yml` (gitignored).
Value: `01585C-551A25-735AA8`.
