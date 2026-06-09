# vivado-image.pkr.hcl
# Bakes a GCP custom image with Vivado 2020.1 installed.
# Build:  packer init . && packer build -var project_id=<your-project> .

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
  project_id          = var.project_id
  zone                = var.zone
  source_image_family = "ubuntu-2004-lts"
  source_image_project_id = ["ubuntu-os-cloud"]
  machine_type        = "n2-standard-8"  # bigger = faster install, only used during bake
  disk_size           = 120              # Vivado is ~50 GB extracted
  disk_type           = "pd-ssd"
  image_name          = "vivado-2020-1-{{timestamp}}"
  image_family        = "vivado-redpitaya"
  ssh_username        = "packer"
}

build {
  sources = ["source.googlecompute.vivado"]

  # System deps Vivado 2020.1 needs on Ubuntu 20.04
  provisioner "shell" {
    inline = [
      "sudo apt-get update",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \\",
      "  libtinfo5 libncurses5 libx11-6 libxrender1 libxtst6 libxi6 \\",
      "  libxrandr2 libfreetype6 libfontconfig1 \\",
      "  git make build-essential python3 python3-pip \\",
      "  google-cloud-cli",
    ]
  }

  # Pull installer from GCS (you upload the .tar.gz once to your own bucket)
  provisioner "shell" {
    inline = [
      "mkdir -p /tmp/vivado",
      "gsutil cp ${var.vivado_installer_gcs} /tmp/vivado/installer.tar.gz",
      "cd /tmp/vivado && tar xf installer.tar.gz && rm installer.tar.gz",
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

  # Auto-source Vivado for all interactive shells
  provisioner "shell" {
    inline = [
      "echo 'source /tools/Xilinx/Vivado/2020.1/settings64.sh' | \\",
      "  sudo tee /etc/profile.d/vivado.sh",
      "sudo chmod +x /etc/profile.d/vivado.sh",
    ]
  }

  # Cable drivers (needed only if you ever attach a board, harmless otherwise)
  provisioner "shell" {
    inline = [
      "sudo /tools/Xilinx/Vivado/2020.1/data/xicom/cable_drivers/lin64/install_script/install_drivers/install_drivers || true",
    ]
  }
}
