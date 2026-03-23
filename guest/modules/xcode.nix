# Xcode support — mount host's Xcode.app and developer tools into the guest.
#
# Mounts /Applications/Xcode.app and /Library/Developer read-only from the
# host via VirtioFS. The host must have Xcode installed and set up (license
# accepted, first launch completed). The guest gets the fully configured
# toolchain without running any installer steps.
#
# This works because:
# - /Library/Developer contains everything xcodebuild -runFirstLaunch installs
#   (CoreSimulator framework, device types, PrivateFrameworks, Toolchains)
# - Simulator device state goes to ~/Library/Developer/ (per-user, writable)
# - VirtioFS follows APFS volume boundaries, so simulator runtimes stored in
#   CoreSimulator/Volumes/ sub-volumes are accessible through the mount
# - Read-only enforcement is at the VirtioFS device level (EROFS), not just
#   host file permissions
#
# Requires VM restart when first enabled (VirtioFS devices are boot-time).

{ lib, config, ... }:

let
  cfg = config.dvm.xcode;
  username = config.system.primaryUser;
in
{
  options.dvm.xcode = {
    enable = lib.mkEnableOption "Xcode support (mounts host Xcode + developer tools read-only)";
  };

  config = lib.mkIf cfg.enable {
    # Mount Xcode.app and /Library/Developer read-only from host.
    # These are system mounts: same absolute path in guest, read-only VirtioFS.
    dvm.mounts.system = [
      "/Applications/Xcode.app"
      "/Library/Developer"
    ];

    # Set DEVELOPER_DIR globally — xcrun needs this to find SDKs.
    environment.variables.DEVELOPER_DIR =
      "/Applications/Xcode.app/Contents/Developer";

    # Activation-time setup: xcode-select, license acceptance, permissions fix.
    # Runs on every activation (idempotent). Appended after guest-plumbing's
    # postActivation (nix daemon socket, /run/current-system).
    #
    # On first boot, activation runs BEFORE VirtioFS mounts are up, so
    # /Applications/Xcode.app won't exist yet. The guard below skips setup
    # in that case. The next `dvm switch` (mounts already active) will
    # run it successfully.
    system.activationScripts.postActivation.text = lib.mkAfter ''
      # Guard: skip Xcode setup if the VirtioFS mount isn't active yet.
      # This happens on first boot (activation precedes mount phase).
      if [ -d /Applications/Xcode.app/Contents ]; then
        /usr/bin/xcode-select -s /Applications/Xcode.app/Contents/Developer 2>/dev/null || true

        # Write license acceptance plist. Values are read from the mounted
        # Xcode.app so they stay in sync when the host updates Xcode.
        _xcode_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
          /Applications/Xcode.app/Contents/Info.plist 2>/dev/null) || true
        _license_id=$(/usr/libexec/PlistBuddy -c "Print :licenseID" \
          /Applications/Xcode.app/Contents/Resources/LicenseInfo.plist 2>/dev/null) || true
        _license_type=$(/usr/libexec/PlistBuddy -c "Print :licenseType" \
          /Applications/Xcode.app/Contents/Resources/LicenseInfo.plist 2>/dev/null) || true
        _license_type=''${_license_type:-GM}

        if [ -n "$_xcode_version" ] && [ -n "$_license_id" ]; then
          defaults write /Library/Preferences/com.apple.dt.Xcode \
            "IDEXcodeVersionForAgreedTo''${_license_type}License" "$_xcode_version"
          defaults write /Library/Preferences/com.apple.dt.Xcode \
            "IDELast''${_license_type}LicenseAgreedTo" "$_license_id"
        fi
      fi

      # Fix ~/Library/Logs permissions. macOS creates this directory at boot
      # but on VirtioFS-backed home (dvm-home) the execute bit may be missing,
      # which prevents CoreSimulatorService from writing device logs.
      _logs_dir="/Users/${username}/Library/Logs"
      if [ -d "$_logs_dir" ]; then
        chmod u+x "$_logs_dir" 2>/dev/null || true
      fi
    '';
  };
}
