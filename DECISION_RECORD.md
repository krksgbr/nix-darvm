# Decision Record

Architectural and design decisions for DVM, with context and rationale.

## DR-001: Minimal base image with SSH bootstrap

**Date:** 2026-03-19
**Status:** Accepted

**Context:** Every change to `guest/agent` or `guest/host-cmd` triggered a full
base image rebuild (~5 min). The image hash covered source directories that
changed frequently during development.

**Decision:** Strip the base image to the absolute minimum. Everything else
arrives via nix-darwin `switch`.

**Minimal image contains:**
- macOS (Cirrus Labs tahoe-base)
- Nix (Determinate installer)
- Passwordless sudo
- `/etc/zshenv` rename (for nix-darwin)
- sshd (already in base image)
- `/nix/store` VirtioFS mount script + LaunchDaemon (see DR-002)

**Bootstrap sequence:**
1. First boot: host SSHs in, mounts `/nix/store`, runs `darwin-rebuild activate`
2. nix-darwin installs everything: agent, host-cmd, services, mount script
3. Subsequent boots: mount script runs at boot, agent starts from nix store

**Consequence:** Day-to-day iteration is `just build && dvm switch`. Image
rebuilds only when the Packer template changes (rare).

---

## DR-002: VirtioFS /nix/store requires explicit mount script

**Date:** 2026-03-19
**Status:** Accepted

**Context:** We explored every option to avoid baking anything guest-side for
the `/nix/store` VirtioFS mount:

1. **fstab entry** (`nix-store /nix/store virtiofs rw 0 0`) — macOS does not
   process VirtioFS fstab entries at boot. Tested: entry present but no mount.
2. **VZ automount tag** (`macOSGuestAutomountTag` / `com.apple.virtio-fs.automount`)
   — macOS auto-mounts this to `/Volumes/My Shared Files`, not to a custom path.
   Cannot automount directly to `/nix/store`.
3. **autofs / auto_master** — designed for NFS/directory services, not VirtioFS.
4. **VZ framework-level mount** — the framework exposes a device to the guest;
   the guest must explicitly mount it. No "pre-mounted" option exists.

**Decision:** Accept a tiny mount script (~5 lines) + LaunchDaemon plist as the
one thing beyond macOS+Nix+sudo that must be baked into the image. On first
boot this is delivered by SSH; on subsequent boots nix-darwin manages it.

**The mount script is truly stable** — it runs `mount_virtiofs nix-store /nix/store`
and never needs to change.

**Consequence:** The minimal image has one small LaunchDaemon beyond the OS
baseline. This is the irreducible minimum for VirtioFS on macOS guests.

---

## DR-003: Credential proxy is opt-in

**Date:** 2026-03-19
**Status:** Accepted

**Context:** The credential proxy replaces NAT networking with
`VZFileHandleNetworkDeviceAttachment` + gVisor sidecar. This changes the
networking model fundamentally: SSH from host to guest no longer works (gVisor
doesn't route inbound connections).

**Decision:** The credential proxy is opt-in. Default networking is NAT (SSH
works, no credential injection). When a `.dvm/credentials.toml` is present,
the proxy activates.

**Consequence:**
- Without credentials configured: full SSH access, standard NAT, all existing
  behavior unchanged.
- With credentials configured: vsock is the only host→guest path. If the agent
  fails, the VM is unreachable until credentials are disabled.
- This is an acceptable trade: users who enable credential injection accept
  the narrower failure mode.

---

## DR-004: CA generated in Go sidecar, not Swift host

**Date:** 2026-03-19
**Status:** Accepted

**Context:** HTTPS MITM requires a CA certificate. We first implemented CA
generation in Swift using manual DER/ASN.1 construction (`EphemeralCA.swift`).
The generated certificate was malformed — Go's `x509.ParseCertificate` rejected
it.

**Decision:** Generate the CA in Go using `crypto/x509.CreateCertificate` (stdlib,
battle-tested). The sidecar generates the CA on startup and returns the PEM to
dvm-core via the control socket `ready` response.

**Consequence:** `EphemeralCA.swift` is dead code (should be deleted). CA
generation is reliable. The host only needs to install the PEM in the guest
trust store, not generate it.

---

## DR-005: Sidecar FD passed via stdin

**Date:** 2026-03-19
**Status:** Accepted

**Context:** The Go sidecar needs the VZ socketpair FD for raw Ethernet frame
I/O. Swift's `Process` (NSTask) uses `posix_spawn` which only inherits stdin,
stdout, and stderr. Arbitrary FDs are not inherited even with `FD_CLOEXEC`
cleared.

**Decision:** Pass the socketpair FD as stdin (fd 0). The sidecar wraps it with
`net.FileConn(os.Stdin)` at startup.

**Alternative considered:** Direct `posix_spawn` with `posix_spawn_file_actions_adddup2`
to place the FD at fd 3. More "proper" but unnecessary complexity for a single FD.

**Consequence:** The sidecar's stdin is not available for human interaction
(acceptable — all control goes through the Unix socket). Logs go to stderr.

---

## DR-006: gvisor-tap-vsock as networking library

**Date:** 2026-03-19
**Status:** Accepted

**Context:** We initially wrote custom DHCP, DNS, and frame I/O code (~500 lines)
on top of raw gVisor netstack. The DHCP server had a broadcast handling bug
(used UDP forwarder instead of bound endpoint). The DNS forwarder was minimal.

**Decision:** Replace custom networking with `gvisor-tap-vsock` as a Go library
dependency. It provides battle-tested DHCP, DNS, and frame I/O used by Podman,
Lima, and Colima in production.

**We kept:** Our custom TCP handler (credential interception for port 80/443)
and the control socket protocol.

**Key integration details:**
- Frame I/O: `tap.Switch` + `tap.NewLinkEndpoint`
- Protocol: `types.VfkitProtocol` (bare L2 over SOCK_DGRAM), not `QemuProtocol`
- Route table: must use `header.IPv4EmptySubnet`, not `tcpip.Subnet{}`
- No custom UDP forwarder: conflicts with library-managed DHCP/DNS bound endpoints

**Consequence:** ~500 lines of custom networking deleted. DHCP works correctly
on first try. DNS forwarding uses host resolver automatically.
