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
  default = "darvm-base"
}

variable "dvm_agent_src" {
  type        = string
  description = "Path to darvm-agent Go source directory"
}

variable "dvm_host_cmd_src" {
  type        = string
  description = "Path to dvm-host-cmd Go source directory"
}

source "tart-cli" "dvm_base" {
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
  sources = ["source.tart-cli.dvm_base"]

  # Install Determinate Nix (handles APFS volume, flakes enabled by default)
  provisioner "shell" {
    inline = [
      "set -euxo pipefail",
      "curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install --no-confirm",
      "test -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh",
    ]
  }

  # Install boot-time VirtioFS mount for /nix/store.
  # After `dvm switch` activates nix-darwin, /etc files become symlinks to
  # host nix store paths (shared via VirtioFS). This LaunchDaemon mounts the
  # host's /nix/store over the guest's local store at boot, before sshd and
  # other services read their nix-store-linked configs.
  # Harmlessly fails when the VM is not run via dvm (no VirtioFS device).
  provisioner "shell" {
    inline = [
      "set -euxo pipefail",

      # Mount script: wait for APFS /nix, then overlay host store via VirtioFS
      "sudo mkdir -p /usr/local/bin",
      <<-SCRIPT
      sudo tee /usr/local/bin/dvm-mount-store > /dev/null << 'EOF'
#!/bin/sh
for i in $(seq 1 30); do
    if [ -d /nix/store ]; then
        /sbin/mount_virtiofs nix-store /nix/store 2>/dev/null && exit 0
    fi
    sleep 1
done
exit 1
EOF
      SCRIPT
      ,
      "sudo chmod 755 /usr/local/bin/dvm-mount-store",

      # LaunchDaemon: run mount script at boot before other services
      <<-PLIST
      sudo tee /Library/LaunchDaemons/com.darvm.mount-store.plist > /dev/null << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.darvm.mount-store</string>
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
    ]
  }

  # Passwordless sudo for the admin user.
  # dvm runs mount/symlink/launchctl commands via non-interactive SSH (no PTY,
  # stdin=/dev/null). Without NOPASSWD, sudo cannot authenticate and silently fails.
  provisioner "shell" {
    inline = [
      "echo 'admin ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/admin",
      "sudo chmod 440 /etc/sudoers.d/admin",
    ]
  }

  # Rename /etc/zshenv so nix-darwin can manage it.
  # Determinate Nix creates /etc/zshenv with SSH-only nix sourcing.
  # nix-darwin needs to own /etc/zshenv and will refuse to activate if
  # it contains unrecognized content. The rename lets activation proceed;
  # nix-darwin's shellInit (in guest-plumbing.nix) sources nix unconditionally.
  provisioner "shell" {
    inline = [
      "sudo mv /etc/zshenv /etc/zshenv.before-nix-darwin || true",
    ]
  }

  # Verify sshd is healthy (Cirrus Labs base image has it enabled)
  provisioner "shell" {
    inline = [
      "sudo /usr/sbin/sshd -T > /dev/null 2>&1",
    ]
  }

  # Install darvm-agent: gRPC server for host↔guest communication.
  # Built from source inside the VM using nix (Go toolchain).
  # Must be baked into the base image because the RPC component runs at boot
  # before /nix/store VirtioFS mount — it handles the mount via gRPC Exec.
  provisioner "file" {
    source      = var.dvm_agent_src
    destination = "/tmp/guest-agent"
  }

  provisioner "shell" {
    inline = [
      "set -euxo pipefail",
      ". /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh",
      "cd /tmp/guest-agent",
      "nix shell nixpkgs#go -c go build -o /tmp/darvm-agent ./cmd/",
      "sudo mv /tmp/darvm-agent /usr/local/bin/darvm-agent",
      "sudo chmod 755 /usr/local/bin/darvm-agent",
      "sudo rm -rf /tmp/guest-agent",

      # LaunchDaemon: gRPC RPC server on vsock port 6175
      <<-PLIST
      sudo tee /Library/LaunchDaemons/com.darvm.agent-rpc.plist > /dev/null << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.darvm.agent-rpc</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/darvm-agent</string>
        <string>--run-rpc</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
EOF
      PLIST
      ,

      # LaunchDaemon: nix daemon bridge (proxies to host via vsock)
      <<-PLIST2
      sudo tee /Library/LaunchDaemons/com.darvm.agent-bridge.plist > /dev/null << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.darvm.agent-bridge</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/darvm-agent</string>
        <string>--run-bridge</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
EOF
      PLIST2
      ,
    ]
  }

  # Install dvm-host-cmd: guest→host command forwarder over vsock.
  # Used via symlinks (busybox pattern) to transparently forward commands
  # like `notify` and `agent-attention` to the host.
  provisioner "file" {
    source      = var.dvm_host_cmd_src
    destination = "/tmp/host-cmd"
  }

  provisioner "shell" {
    inline = [
      "set -euxo pipefail",
      ". /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh",
      "cd /tmp/host-cmd",
      "nix shell nixpkgs#go -c go build -o /tmp/dvm-host-cmd .",
      "sudo mv /tmp/dvm-host-cmd /usr/local/bin/dvm-host-cmd",
      "sudo chmod 755 /usr/local/bin/dvm-host-cmd",
      "sudo rm -rf /tmp/host-cmd",
    ]
  }

  # Base image contents: Determinate Nix + sshd + VirtioFS store mount +
  # passwordless sudo + darvm-agent (gRPC + nix daemon bridge) +
  # dvm-host-cmd (guest→host command forwarder).
  # nix-darwin and agents are layered on by `dvm switch`.
}
