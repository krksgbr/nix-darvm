import Foundation
import Virtualization

/// A configured, ready-to-boot VM. Binds the VZ machine to the config it was
/// created from, so the MAC address used for IP resolution always belongs to
/// the actual VM instance. `effectiveMounts` contains only the mounts that were
/// actually installed into the VM configuration (host paths that exist).
@MainActor
struct ConfiguredVM {
    let vm: VZVirtualMachine
    let macAddress: VZMACAddress
    let effectiveMounts: [MountConfig]
}

/// Creates a VZVirtualMachineConfiguration from a Tart VM directory.
///
/// Reference: Lume's DarwinVirtualizationService.createConfiguration()
/// and Tart's VM.craftConfiguration(). Stripped to headless essentials.
@MainActor
enum VMConfigurator {

    struct VMPaths {
        let config: URL
        let disk: URL
        let nvram: URL

        init(vmDir: URL) {
            config = vmDir.appendingPathComponent("config.json")
            disk = vmDir.appendingPathComponent("disk.img")
            nvram = vmDir.appendingPathComponent("nvram.bin")
        }
    }

    /// Create a configured VM.
    ///
    /// - Parameters:
    ///   - vmDir: Path to the Tart VM directory
    ///   - mounts: VirtioFS mount configurations
    ///   - netstackFD: When non-nil, use VZFileHandleNetworkDeviceAttachment with
    ///     this file descriptor instead of NAT. The FD is the VM-side of a socketpair
    ///     shared with the dvm-netstack sidecar for transparent credential injection.
    ///   - stateDir: When non-nil, expose this host directory as VirtioFS device
    ///     `dvm-state` for activation state exchange between host and guest.
    ///   - homeDataDir: Host directory backing the guest user's home (`/Users/admin`).
    ///     Exposed as VirtioFS device `dvm-home`, mounted by the guest's boot script
    ///     before any launchd services touch `~/`. This is infrastructure — always
    ///     presented, never skipped. The guest halts if this mount fails.
    static func create(
        vmDir: URL,
        mounts: [MountConfig],
        netstackFD: Int32? = nil,
        stateDir: URL? = nil,
        homeDataDir: URL
    ) throws -> ConfiguredVM {
        let paths = VMPaths(vmDir: vmDir)
        let config = try TartConfig(fromURL: paths.config)

        let vzConfig = VZVirtualMachineConfiguration()
        vzConfig.cpuCount = config.cpuCount
        vzConfig.memorySize = config.memorySize

        // Platform (macOS on Apple Silicon)
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = config.hardwareModel
        platform.machineIdentifier = config.machineIdentifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: paths.nvram)
        vzConfig.platform = platform

        // Boot loader
        vzConfig.bootLoader = VZMacOSBootLoader()

        // Storage
        let diskAttachment = try VZDiskImageStorageDeviceAttachment(
            url: paths.disk,
            readOnly: false,
            cachingMode: .automatic,
            synchronizationMode: .fsync
        )
        vzConfig.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]

        // Network: FileHandle (netstack sidecar) or NAT (default)
        let network = VZVirtioNetworkDeviceConfiguration()
        network.macAddress = config.macAddress
        if let fd = netstackFD {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            network.attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: handle)
        } else {
            network.attachment = VZNATNetworkDeviceAttachment()
        }
        vzConfig.networkDevices = [network]

        // VirtioFS — each mount gets its own VZSingleDirectoryShare device,
        // mounted at the same path in the guest so `pwd` matches the host.
        var fsDevices: [VZDirectorySharingDeviceConfiguration] = []
        var effectiveMounts: [MountConfig] = []

        for mount in mounts {
            guard case .exact(let tag, let hostPath, _, let access) = mount else { continue }
            guard FileManager.default.fileExists(atPath: hostPath.rawValue) else {
                print("Warning: skipping mount \(tag), host path does not exist: \(hostPath)")
                continue
            }
            let device = VZVirtioFileSystemDeviceConfiguration(tag: tag.rawValue)
            device.share = VZSingleDirectoryShare(
                directory: VZSharedDirectory(
                    url: URL(fileURLWithPath: hostPath.rawValue), readOnly: access == .readOnly)
            )
            fsDevices.append(device)
            effectiveMounts.append(mount)
        }

        // dvm-state VirtioFS: host↔guest activation state exchange.
        // Guest mount script mounts this at /var/run/dvm-state.
        if let stateDir {
            let device = VZVirtioFileSystemDeviceConfiguration(tag: "dvm-state")
            device.share = VZSingleDirectoryShare(
                directory: VZSharedDirectory(url: stateDir, readOnly: false))
            fsDevices.append(device)
        }

        // dvm-home VirtioFS: host-backed guest home directory.
        // Mounted at /Users/admin by the guest's boot script (dvm-mount-store)
        // before any launchd services run. This is infrastructure — the guest
        // disk is too small for user data (~1GB free after macOS), so all user
        // state lives on the host at ~/.local/state/dvm/home/.
        // Unlike optional user mounts, this is never skipped — the host must
        // ensure the directory exists before calling create().
        do {
            let device = VZVirtioFileSystemDeviceConfiguration(tag: "dvm-home")
            device.share = VZSingleDirectoryShare(
                directory: VZSharedDirectory(url: homeDataDir, readOnly: false))
            fsDevices.append(device)
        }

        if !fsDevices.isEmpty {
            vzConfig.directorySharingDevices = fsDevices
        }

        // Graphics (required for macOS guest to boot, even headless)
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [
            VZMacGraphicsDisplayConfiguration(
                widthInPixels: 1024,
                heightInPixels: 768,
                pixelsPerInch: 220
            )
        ]
        vzConfig.graphicsDevices = [graphics]

        // Vsock (host↔guest channel for nix daemon bridge, future IPC)
        vzConfig.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        // Entropy
        vzConfig.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // Memory balloon
        vzConfig.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        try vzConfig.validate()
        return ConfiguredVM(
            vm: VZVirtualMachine(configuration: vzConfig),
            macAddress: config.macAddress,
            effectiveMounts: effectiveMounts
        )
    }
}
