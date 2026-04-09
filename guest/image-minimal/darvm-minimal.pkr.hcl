// Minimal base image for DVM.
// Contains only: macOS + Nix + sudo + VirtioFS mount script + WatchPaths activator.
// No agent, no host-cmd, no nix-darwin. Everything else arrives via activation.

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
  disk_size_gb = 150
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

  # 4. Mount script + activator + LaunchDaemons.
  # The mount script runs at boot to mount host VirtioFS shares before any
  # nix-darwin services start. The activator watches a trigger file and runs
  # nix-darwin activation when signaled. Together they bootstrap the entire
  # guest state from nix config without needing SSH or a pre-installed agent.
  #
  # WHY THE ACTIVATOR IS BAKED INTO THE IMAGE (not delivered via nix-darwin):
  # Bootstrap problem. The activator's job is to run `darwin-rebuild activate`
  # for the first time. nix-darwin cannot deliver the activator because nix-darwin
  # has not been activated yet when the activator first runs — the agent, modules,
  # and all nix-darwin-managed content don't exist until the activator creates them.
  # The activator must therefore exist before nix-darwin exists. Managing it from
  # a nix-darwin module after first activation is possible but creates two code
  # paths (image version + nix version) that must stay in sync, which is fragile.
  #
  # ITERATING WITHOUT AN IMAGE REBUILD: use `just push-image-scripts` to push
  # scripts/dvm-activator and scripts/dvm-mount-store to a running VM, then
  # restart. The image rebuild is only needed to make changes permanent.
  provisioner "file" {
    sources = [
      "${path.root}/scripts/dvm-activator",
      "${path.root}/scripts/dvm-mount-store",
    ]
    destination = "/tmp/"
  }

  provisioner "shell" {
    inline = [
      "set -euxo pipefail",
      "sudo mkdir -p /usr/local/bin",
      "sudo install -m 755 /tmp/dvm-activator /usr/local/bin/dvm-activator",
      "sudo install -m 755 /tmp/dvm-mount-store /usr/local/bin/dvm-mount-store",

      # LaunchDaemon: mount nix-store + dvm-state at boot
      <<-PLIST
      sudo tee /Library/LaunchDaemons/com.dvm.mount-store.plist > /dev/null << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.dvm.mount-store</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/dvm-mount-store</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOF
      PLIST
      ,

      # LaunchDaemon: activator — fires when trigger file is touched
      <<-PLIST2
      sudo tee /Library/LaunchDaemons/com.dvm.activator.plist > /dev/null << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.dvm.activator</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/dvm-activator</string>
    </array>
    <key>WatchPaths</key>
    <array>
        <string>/var/run/dvm-state/trigger</string>
    </array>
</dict>
</plist>
EOF
      PLIST2
      ,
    ]
  }

  # 5. Verify sshd is healthy
  provisioner "shell" {
    inline = [
      "sudo /usr/sbin/sshd -T > /dev/null 2>&1",
    ]
  }

  # That's it. No agent, no host-cmd, no LaunchDaemons for them.
  # Everything above nix arrives via nix-darwin activation.
}
