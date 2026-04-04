import Foundation
import Virtualization

/// A configured, ready-to-boot VM. Binds the VZ machine to the config it was
/// created from, so the MAC address used for IP resolution always belongs to
/// the actual VM instance. `effectiveMounts` contains only the mounts that were
/// actually installed into the VM configuration (host paths that exist).
@MainActor
struct ConfiguredVM {
    let virtualMachine: VZVirtualMachine
    let macAddress: VZMACAddress
    let nfsMACAddress: VZMACAddress?
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

        configurePlatform(vzConfig, tartConfig: config, paths: paths)
        try configureStorage(vzConfig, diskURL: paths.disk)
        let network = makeNetworkDevices(
            tartConfig: config,
            mounts: mounts,
            netstackFD: netstackFD
        )
        vzConfig.networkDevices = network.devices
        let directoryShares = makeDirectorySharingDevices(
            mounts: mounts,
            stateDir: stateDir,
            homeDataDir: homeDataDir
        )
        vzConfig.directorySharingDevices = directoryShares.devices
        configureAuxiliaryDevices(vzConfig)

        try vzConfig.validate()
        return ConfiguredVM(
            virtualMachine: VZVirtualMachine(configuration: vzConfig),
            macAddress: network.primaryMAC,
            nfsMACAddress: network.nfsMACAddress,
            effectiveMounts: directoryShares.effectiveMounts
        )
    }

    private static func configurePlatform(
        _ config: VZVirtualMachineConfiguration,
        tartConfig: TartConfig,
        paths: VMPaths
    ) {
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = tartConfig.hardwareModel
        platform.machineIdentifier = tartConfig.machineIdentifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: paths.nvram)
        config.platform = platform
        config.bootLoader = VZMacOSBootLoader()
    }

    private static func configureStorage(
        _ config: VZVirtualMachineConfiguration,
        diskURL: URL
    ) throws {
        let diskAttachment = try VZDiskImageStorageDeviceAttachment(
            url: diskURL,
            readOnly: false,
            cachingMode: .automatic,
            synchronizationMode: .fsync
        )
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]
    }

    private static func makeNetworkDevices(
        tartConfig: TartConfig,
        mounts: [MountConfig],
        netstackFD: Int32?
    ) -> (devices: [VZNetworkDeviceConfiguration], primaryMAC: VZMACAddress, nfsMACAddress: VZMACAddress?) {
        let primaryNetwork = VZVirtioNetworkDeviceConfiguration()
        let primaryMAC =
            netstackFD != nil
            ? VZMACAddress.randomLocallyAdministered()
            : tartConfig.macAddress
        primaryNetwork.macAddress = primaryMAC
        if let fileDescriptor = netstackFD {
            let handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: false)
            primaryNetwork.attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: handle)
        } else {
            primaryNetwork.attachment = VZNATNetworkDeviceAttachment()
        }

        guard mounts.contains(where: { $0.transport == .nfs && $0.isMirror }) else {
            return ([primaryNetwork], primaryMAC, nil)
        }

        let nfsNetwork = VZVirtioNetworkDeviceConfiguration()
        let nfsMACAddress = VZMACAddress.randomLocallyAdministered()
        nfsNetwork.macAddress = nfsMACAddress
        nfsNetwork.attachment = VZNATNetworkDeviceAttachment()
        return ([primaryNetwork, nfsNetwork], primaryMAC, nfsMACAddress)
    }

    private static func makeDirectorySharingDevices(
        mounts: [MountConfig],
        stateDir: URL?,
        homeDataDir: URL
    ) -> (devices: [VZDirectorySharingDeviceConfiguration], effectiveMounts: [MountConfig]) {
        var devices: [VZDirectorySharingDeviceConfiguration] = []
        var effectiveMounts: [MountConfig] = []

        for mount in mounts {
            guard includeMount(mount, in: &devices) else { continue }
            effectiveMounts.append(mount)
        }

        if let stateDir {
            devices.append(makeSharedDirectoryDevice(tag: "dvm-state", directoryURL: stateDir, readOnly: false))
        }

        devices.append(makeSharedDirectoryDevice(tag: "dvm-home", directoryURL: homeDataDir, readOnly: false))
        return (devices, effectiveMounts)
    }

    private static func includeMount(
        _ mount: MountConfig,
        in devices: inout [VZDirectorySharingDeviceConfiguration]
    ) -> Bool {
        let tag = mount.tag
        let hostPath = mount.hostPath
        guard FileManager.default.fileExists(atPath: hostPath.rawValue) else {
            print("Warning: skipping mount \(tag), host path does not exist: \(hostPath)")
            return false
        }
        if mount.transport == .virtiofs {
            devices.append(
                makeSharedDirectoryDevice(
                    tag: tag.rawValue,
                    directoryURL: URL(fileURLWithPath: hostPath.rawValue),
                    readOnly: mount.access == .readOnly
                ))
        }
        return true
    }

    private static func makeSharedDirectoryDevice(
        tag: String,
        directoryURL: URL,
        readOnly: Bool
    ) -> VZDirectorySharingDeviceConfiguration {
        let device = VZVirtioFileSystemDeviceConfiguration(tag: tag)
        device.share = VZSingleDirectoryShare(
            directory: VZSharedDirectory(url: directoryURL, readOnly: readOnly)
        )
        return device
    }

    private static func configureAuxiliaryDevices(_ config: VZVirtualMachineConfiguration) {
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [
            VZMacGraphicsDisplayConfiguration(
                widthInPixels: 1_024,
                heightInPixels: 768,
                pixelsPerInch: 220
            )
        ]
        config.graphicsDevices = [graphics]
        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
    }
}
