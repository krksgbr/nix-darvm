# macOS VirtioFS does not support Unix domain sockets

Date: 2026-03-24

## Summary

`bind()` for `AF_UNIX` sockets on a macOS VirtioFS mount fails with
`ENOTSUP` (errno 45, "Operation not supported"). This affects any tool
that creates Unix domain sockets on a shared filesystem: process managers
(process-compose), databases (PostgreSQL, Redis), language servers, etc.

This is a separate limitation from the nested mount vnode instability
documented in `macos-virtiofs-nested-mount-failure.md`.

## Reproduction

In a macOS guest with a VirtioFS mirror mount at `/path/on/virtiofs`:

```
$ python3 -c "import socket,os; s = socket.socket(socket.AF_UNIX); s.bind('/path/on/virtiofs/test.sock'); print('OK'); s.close(); os.unlink('/path/on/virtiofs/test.sock')"

Traceback (most recent call last):
  File "<string>", line 1, in <module>
    import socket,os; s = socket.socket(socket.AF_UNIX); s.bind('/path/on/virtiofs/test.sock'); ...
                                                          ~~~~~~^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
OSError: [Errno 45] Operation not supported
```

The same operation succeeds on guest-local filesystems (`/tmp`, `/var`, the
guest's APFS boot volume):

```
$ python3 -c "import socket,os; s = socket.socket(socket.AF_UNIX); s.bind('/tmp/test.sock'); print('OK'); s.close(); os.unlink('/tmp/test.sock')"
OK
```

## Root cause

Apple's VirtioFS implementation (AppleVirtIOFS.kext) does not implement the
`mknod` FUSE operation for socket-type files. When the kernel's VFS layer
calls through to the VirtioFS filesystem to create a socket inode during
`bind()`, the filesystem returns `ENOTSUP`.

Linux VirtioFS (virtiofsd / FUSE) does support socket creation, so this is
macOS-specific.

## Practical impact

Any tool that creates a Unix socket at a path on a VirtioFS mount will fail.
In DVM, both mirror mounts (project directories) and home mounts (via
`/var/dvm-mounts/`) are VirtioFS. Common affected tools:

| Tool | Socket path | Fails in guest |
|------|-------------|----------------|
| process-compose | `$PROJECT/.chell/runtime/*/pc.sock` | Yes |
| PostgreSQL | `$PROJECT/.chell/runtime/*/postgres/.s.PGSQL.5432` | Yes |
| Redis | configured socket path | Yes, if on VirtioFS |
| Docker socket | `/var/run/docker.sock` | No (guest-local) |
| nix daemon | `/tmp/nix-daemon.sock` | No (guest-local) |

## Implications for DVM

DVM sets `DVM_GUEST=1` in the guest environment so projects can detect the
VM context if needed. However, projects should not condition socket paths on
this — **socket paths should always be on a local filesystem** (e.g., `/tmp`)
regardless of environment, since this is also the correct behavior for
network filesystems (NFS, SMB) which have the same limitation.

DVM's own infrastructure already avoids this: the nix daemon bridge uses
`/tmp/nix-daemon.sock`, the control socket uses `/tmp/dvm-control.sock`,
and the agent communicates via vsock (no filesystem socket at all).
