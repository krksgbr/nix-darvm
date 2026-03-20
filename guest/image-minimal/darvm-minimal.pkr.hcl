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

  # 4. Mount script + activator + LaunchDaemons.
  # The mount script runs at boot to mount host VirtioFS shares before any
  # nix-darwin services start. The activator watches a trigger file and runs
  # nix-darwin activation when signaled. Together they bootstrap the entire
  # guest state from nix config without needing SSH or a pre-installed agent.
  provisioner "shell" {
    inline = [
      "set -euxo pipefail",

      # Mount script: mounts nix-store and dvm-state at boot
      "sudo mkdir -p /usr/local/bin",
      <<-SCRIPT
      sudo tee /usr/local/bin/dvm-mount-store > /dev/null << 'EOF'
#!/bin/sh
LOG=/var/log/dvm-boot.log
mkdir -p /var/run/dvm-state

# Mount nix store from host
for i in $(seq 1 30); do
    if mount_virtiofs nix-store /nix/store 2>/dev/null; then
        echo "$(date): mounted nix-store on /nix/store" >> "$LOG"
        break
    fi
    sleep 1
done

# Mount state directory from host (may not exist if no activation requested)
mount_virtiofs dvm-state /var/run/dvm-state 2>/dev/null && \
    echo "$(date): mounted dvm-state" >> "$LOG"

# Touch trigger if closure-path exists (first boot activation)
if [ -f /var/run/dvm-state/closure-path ]; then
    touch /var/run/dvm-state/trigger
fi
EOF
      SCRIPT
      ,
      "sudo chmod 755 /usr/local/bin/dvm-mount-store",

      # Activator script: reads closure path, runs darwin-rebuild activate.
      # Handles profile symlink update and link-nix-apps workaround so the
      # host doesn't need gRPC access during activation.
      <<-SCRIPT2
      sudo tee /usr/local/bin/dvm-activator > /dev/null << 'EOF'
#!/bin/sh
STATE_DIR="/var/run/dvm-state"
CLOSURE=$(cat "$STATE_DIR/closure-path" 2>/dev/null)
RUN_ID=$(cat "$STATE_DIR/run-id" 2>/dev/null || date +%s)
RUN_DIR="$STATE_DIR/$RUN_ID"
SYSTEM_PROFILE="/nix/var/nix/profiles/system"
mkdir -p "$RUN_DIR"

# Validate closure
if [ -z "$CLOSURE" ] || [ ! -d "$CLOSURE" ]; then
    echo "invalid-closure" > "$RUN_DIR/status"
    echo "Closure not found or empty: $CLOSURE" > "$RUN_DIR/activation.log"
    exit 1
fi

echo "running" > "$RUN_DIR/status"

# Disable link-nix-apps (hangs in headless VMs without GUI session)
launchctl bootout gui/501/org.nix.link-nix-apps 2>/dev/null || true
rm -f /Library/LaunchAgents/org.nix.link-nix-apps.plist

# Update profile symlink before activation — darwin-rebuild reads it
# to diff services and resolve primaryUser.
ln -sfn "$CLOSURE" "$SYSTEM_PROFILE"

# Run activation
"$CLOSURE/sw/bin/darwin-rebuild" activate > "$RUN_DIR/activation.log" 2>&1
CODE=$?
echo "$CODE" > "$RUN_DIR/exit-code"
if [ "$CODE" -eq 0 ]; then
    echo "done" > "$RUN_DIR/status"
else
    echo "failed" > "$RUN_DIR/status"
fi
EOF
      SCRIPT2
      ,
      "sudo chmod 755 /usr/local/bin/dvm-activator",

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
