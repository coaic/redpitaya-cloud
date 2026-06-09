# vivado-image.pkr.hcl
# Bakes a GCP custom image with Vivado 2020.1 + XFCE desktop + XRDP.
# Used for both Cloud Batch synthesis jobs and remote Vivado GUI sessions.
# Build:  packer init . && packer build -var project_id=<your-project> -var vivado_installer_gcs=gs://... .

packer {
  required_plugins {
    googlecompute = {
      source  = "github.com/hashicorp/googlecompute"
      version = "~> 1.1"
    }
  }
}

variable "project_id" {
  type = string
}

variable "zone" {
  type    = string
  default = "australia-southeast1-a"
}

variable "vivado_installer_gcs" {
  type        = string
  description = "gs:// URL of Xilinx_Unified_2020.1_*.tar.gz (upload manually first)"
}

source "googlecompute" "vivado" {
  project_id               = var.project_id
  zone                     = var.zone
  source_image_family      = "ubuntu-pro-2004-lts"
  source_image_project_id  = ["ubuntu-os-pro-cloud"]
  machine_type             = "n2-standard-8"  # only used during bake
  disk_size                = 200              # streamed: OS ~10 GB + extracted ~52 GB + installed ~25 GB + desktop ~1 GB
  disk_type                = "pd-ssd"
  image_name               = "vivado-2020-1-{{timestamp}}"
  image_family             = "vivado-redpitaya"
  ssh_username             = "packer"
  ssh_timeout              = "3h"
}

build {
  sources = ["source.googlecompute.vivado"]

  # System deps: Vivado 2020.1 + XFCE desktop + XRDP
  provisioner "shell" {
    inline = [
      # Ubuntu Pro runs ua-auto-attach on first boot and holds the apt lock.
      "while sudo fuser /var/lib/apt/lists/lock /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do echo 'Waiting for apt lock...'; sleep 5; done",
      "sudo apt-get update",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \\",
      "  libtinfo5 libncurses5 libx11-6 libxrender1 libxtst6 libxi6 \\",
      "  libxrandr2 libfreetype6 libfontconfig1 git make \\",
      "  xfce4 xfce4-goodies xorg dbus-x11 \\",
      "  xrdp",
    ]
  }

  # Stream installer directly from GCS — archive is never written to disk
  provisioner "shell" {
    inline = [
      "set -e",
      "mkdir -p /tmp/vivado",
      "gsutil cp ${var.vivado_installer_gcs} - | tar xz -C /tmp/vivado",
    ]
  }

  # Silent install config (see install_config.txt)
  provisioner "file" {
    source      = "install_config.txt"
    destination = "/tmp/vivado/install_config.txt"
  }

  provisioner "shell" {
    inline = [
      "cd /tmp/vivado/Xilinx_Unified_2020.1_* && \\",
      "  sudo ./xsetup \\",
      "    --agree XilinxEULA,3rdPartyEULA,WebTalkTerms \\",
      "    --batch Install \\",
      "    --config /tmp/vivado/install_config.txt",
      "sudo rm -rf /tmp/vivado",
    ]
  }

  # Auto-source Vivado for all shells (batch jobs and desktop sessions)
  provisioner "shell" {
    inline = [
      "echo 'source /tools/Xilinx/Vivado/2020.1/settings64.sh' | \\",
      "  sudo tee /etc/profile.d/vivado.sh",
      "sudo chmod +x /etc/profile.d/vivado.sh",
    ]
  }

  # Cable drivers (harmless if no board attached)
  provisioner "shell" {
    inline = [
      "sudo /tools/Xilinx/Vivado/2020.1/data/xicom/cable_drivers/lin64/install_script/install_drivers/install_drivers || true",
    ]
  }

  # Configure XRDP to launch an XFCE session
  provisioner "shell" {
    inline = [
      "echo 'startxfce4' > /home/packer/.xsession",
      "chmod +x /home/packer/.xsession",
      "sudo adduser xrdp ssl-cert",
      "sudo systemctl enable xrdp",
      "sudo systemctl enable xrdp-sesman",
    ]
  }
}
