// Minimal base image for testing the SSH bootstrap approach.
// Contains only: macOS + Nix + sudo + sshd + fstab nix-store mount.
// No agent, no host-cmd, no LaunchDaemons.
// Everything else arrives via nix-darwin activation.

packer {
  required_plugins {
    tart = {
      version = ">= 1.16.0"
      source  = "github.com/cirruslabs/tart"
    }
  }
}

variable "base_image" {
  type    = string
  default = "ghcr.io/cirruslabs/macos-tahoe-base@sha256:593df8dcf9f00929c9e8f19e47793657953ba14112830efa7aaccdd214410093"
}

variable "vm_name" {
  type    = string
  default = "darvm-minimal"
}

source "tart-cli" "minimal" {
  vm_base_name = var.base_image
  vm_name      = var.vm_name
  cpu_count    = 4
  memory_gb    = 8
  disk_size_gb = 50
  ssh_username = "admin"
  ssh_password = "admin"
  ssh_timeout  = "180s"
}

build {
  sources = ["source.tart-cli.minimal"]

  # 1. Install Determinate Nix
  provisioner "shell" {
    inline = [
      "set -euxo pipefail",
      "curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install --no-confirm",
      "test -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh",
    ]
  }

  # 2. Passwordless sudo
  provisioner "shell" {
    inline = [
      "echo 'admin ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/admin",
      "sudo chmod 440 /etc/sudoers.d/admin",
    ]
  }

  # 3. Rename /etc/zshenv so nix-darwin can manage it
  provisioner "shell" {
    inline = [
      "sudo mv /etc/zshenv /etc/zshenv.before-nix-darwin || true",
    ]
  }

  # 4. Add fstab entry for VirtioFS nix-store mount.
  # Test: does macOS auto-mount this at boot before LaunchDaemons run?
  # If the VirtioFS device isn't present (VM not run via dvm), mount fails
  # harmlessly — fstab entries with missing devices are skipped.
  provisioner "shell" {
    inline = [
      "echo 'nix-store /nix/store virtiofs rw 0 0' | sudo tee -a /etc/fstab",
    ]
  }

  # 5. Verify sshd is healthy
  provisioner "shell" {
    inline = [
      "sudo /usr/sbin/sshd -T > /dev/null 2>&1",
    ]
  }

  # That's it. No agent, no host-cmd, no LaunchDaemons.
  # Total additions to base image: Nix + sudo + zshenv rename + one fstab line.
}
