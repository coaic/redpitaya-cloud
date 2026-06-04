# Plan: Vivado Remote Desktop on GCP

Cloud-hosted Vivado GUI running on an ephemeral GCP VM, connected to from a Mac via RDP. Uses the existing `vivado-redpitaya` image family (Vivado 2020.1, Ubuntu 20.04). Red Pitaya Gen 2 is the proof-of-concept target.

**Workflow split:**
- **Local (Mac):** edit RTL source files, manage git, submit builds, fetch results
- **Remote desktop (GCP):** Vivado GUI for IP configuration, schematic, simulation, timing analysis — no local synthesis
- **Cloud Batch (existing):** all synthesis / place-and-route runs

---

## Phase 1 — Fix the Packer image build

The current Packer script downloads the installer tar to disk before extracting, which requires the tar + extracted contents + Vivado installation all simultaneously. For Vivado 2020.1 this is borderline; for 2024.2 it fails outright. Fix both issues now before adding the desktop layer.

### 1a. Stream the installer instead of downloading it

Change the extract provisioner from:
```hcl
inline = [
  "gsutil cp ${var.vivado_installer_gcs} /tmp/vivado/installer.tar.gz",
  "cd /tmp/vivado && tar xf installer.tar.gz && rm installer.tar.gz",
]
```
to:
```hcl
inline = [
  "mkdir -p /tmp/vivado",
  "gsutil cp ${var.vivado_installer_gcs} - | tar xz -C /tmp/vivado",
]
```
This pipes GCS directly into tar — the archive is never written to disk. Peak disk usage drops by the full installer size (~52 GB for 2020.1, ~125 GB for 2024.2).

### 1b. Increase disk size

| Version | Peak disk during bake | New disk_size |
|---|---|---|
| 2020.1 (RedPitaya) | ~130 GB | 200 GB |
| 2024.2 (KiwiSDR) | ~200 GB | 300 GB |

### 1c. Verify the bake succeeds before adding desktop

Run Packer with only the Vivado install (no desktop provisioners yet) to confirm the streaming fix works cleanly on a fresh image.

---

## Phase 2 — Add desktop environment to the image

Add XFCE + XRDP to the Packer provisioning sequence, after the Vivado install step. XFCE is chosen over GNOME because it is lightweight, works reliably over RDP, and has no compositing overhead that causes rendering issues in remote sessions.

### Packages to install

```bash
sudo apt-get install -y \
  xfce4 xfce4-goodies \
  xrdp \
  dbus-x11 \
  xorg
```

### XRDP configuration

```bash
# Tell XRDP to launch an XFCE session
echo "startxfce4" > /home/packer/.xsession
sudo systemctl enable xrdp
sudo systemctl enable xrdp-sesman

# Add xrdp user to ssl-cert group (required on Ubuntu 20.04)
sudo adduser xrdp ssl-cert
```

### Vivado display integration

Vivado needs `DISPLAY` set and a functioning X session. In an XRDP session this is provided automatically. No additional configuration needed for batch/GUI mode switching.

### Image family

Keep using `vivado-redpitaya` — the desktop is an addition to the same image, not a separate one. Build jobs (Cloud Batch) never start the desktop session so it has no effect on synthesis performance.

---

## Phase 3 — GCP networking for RDP access

Use **IAP (Identity-Aware Proxy) tunnelling** rather than a public firewall rule. This means:
- No public IP on the VM
- RDP port (3389) is never exposed to the internet
- Authentication is handled by your Google account
- No VPN or bastion host needed

### Firewall rule required

One firewall rule to allow IAP's IP range to reach port 3389:

```bash
gcloud compute firewall-rules create allow-rdp-iap \
  --project=redpitaya-fpga-builds \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp:3389 \
  --source-ranges=35.235.240.0/20 \
  --target-tags=vivado-desktop
```

### IAM permission required

The user connecting needs `roles/iap.tunnelResourceAccessor` on the project (or VM):

```bash
gcloud projects add-iam-policy-binding redpitaya-fpga-builds \
  --member=user:rcoaic@gmail.com \
  --role=roles/iap.tunnelResourceAccessor
```

---

## Phase 4 — VM instance for interactive use

### Instance spec

| Property | Value | Reason |
|---|---|---|
| Machine type | `n2-standard-4` | 4 vCPU, 16 GB RAM — adequate for GUI-only Vivado |
| Provisioning | On-demand (not SPOT) | Session must not be preempted mid-work |
| Boot disk | 80 GB pd-balanced | OS + Vivado already in image, no large workspace needed |
| Boot image | `vivado-redpitaya` family | Latest baked image with desktop |
| Network tag | `vivado-desktop` | Matches the IAP firewall rule above |
| External IP | None | IAP tunnel makes this unnecessary |
| Region | `australia-southeast1` | Same as batch jobs |

### Startup / shutdown

The VM is stopped when not in use — billing is for disk only (~$0.16/day for 80 GB pd-balanced). Start it when needed, stop it when done.

```bash
# Start
gcloud compute instances start vivado-desktop --zone=australia-southeast1-a --project=redpitaya-fpga-builds

# Stop (do this — don't just close the RDP window)
gcloud compute instances stop vivado-desktop --zone=australia-southeast1-a --project=redpitaya-fpga-builds
```

Alternatively, add a shutdown script that runs `sudo poweroff` after N minutes of idle XRDP sessions to prevent accidentally leaving it running.

### Instance creation command

```bash
gcloud compute instances create vivado-desktop \
  --project=redpitaya-fpga-builds \
  --zone=australia-southeast1-a \
  --machine-type=n2-standard-4 \
  --image-family=vivado-redpitaya \
  --image-project=redpitaya-fpga-builds \
  --boot-disk-size=80GB \
  --boot-disk-type=pd-balanced \
  --no-address \
  --tags=vivado-desktop \
  --metadata=enable-oslogin=TRUE
```

---

## Phase 5 — Connecting from Mac

### One-time setup

Install Microsoft Remote Desktop from the Mac App Store (free). This is the client — it handles the RDP session once the tunnel is open.

### Per-session connection

```bash
# 1. Start the VM (if stopped)
gcloud compute instances start vivado-desktop \
  --zone=australia-southeast1-a --project=redpitaya-fpga-builds

# 2. Open IAP tunnel in background
gcloud compute start-iap-tunnel vivado-desktop 3389 \
  --local-host-port=localhost:3389 \
  --zone=australia-southeast1-a \
  --project=redpitaya-fpga-builds &

# 3. Open Microsoft Remote Desktop → New PC → localhost:3389
#    Username: packer (or whichever user was created during Packer bake)
```

Consider wrapping steps 1–2 in a short shell script (`scripts/start-desktop.sh`) so it's a one-liner.

### Session quality settings

In Microsoft Remote Desktop, for Vivado's UI:
- Resolution: match external display resolution
- Colour depth: High Colour (16-bit) — sufficient for Vivado, reduces bandwidth
- Disable sound redirection — not needed, reduces overhead

---

## Phase 6 — Source file access inside the VM

Vivado inside the RDP session needs access to the Red Pitaya RTL sources. Two options:

### Option A — sshfs (simpler)

Mount the Mac's local git repo into the VM over SSH:

```bash
# On the VM (in the RDP session terminal)
sshfs user@mac-local-ip:/path/to/RedPitaya /home/packer/redpitaya -o follow_symlinks
```

Requires the Mac to be reachable from the VM. Works well on a local network.

### Option B — git clone inside the VM (cleaner)

Keep the source in the VM, sync via git push/pull. Edit on Mac, push, pull in VM. Simple and works regardless of network topology.

```bash
# In the VM
git clone git@github.com:ORG/REPO.git ~/redpitaya
# After each push from Mac:
git pull
```

**Recommended: Option B** — keeps the VM self-contained, no SSH mount to manage.

---

## Cost estimate

| Item | Cost | Notes |
|---|---|---|
| `n2-standard-4` running | ~$0.19/hr | Only while RDP session active |
| 80 GB pd-balanced disk | ~$0.16/day | Always-on (stopped VM still has disk) |
| Packer bake VM | ~$0.50 one-time | ~45 min n2-standard-8, then deleted |
| GCS installer bucket | ~$1.00/month | ~52 GB at $0.02/GB |

A 2-hour Vivado GUI session costs ~$0.40. Leaving the VM running overnight would cost ~$1.50 — worth adding the idle-shutdown script.

---

## Implementation order

1. Fix Packer script (Phase 1) — streaming + disk size
2. Add XFCE + XRDP provisioners (Phase 2)
3. Bake new `vivado-redpitaya` image
4. Add IAP firewall rule + IAM binding (Phase 3)
5. Create `vivado-desktop` VM instance (Phase 4)
6. Test connection from Mac via Microsoft Remote Desktop (Phase 5)
7. Clone Red Pitaya repo inside VM, open Vivado, verify GUI works (Phase 6)
8. If successful, apply same pattern to KiwiSDR (Vivado 2024.2)
