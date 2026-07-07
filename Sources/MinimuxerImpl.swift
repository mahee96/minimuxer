//
//  Minimuxer.swift
//  Minimuxer
//
//  Created by Magesh K on 4/7/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation

final internal class MinimuxerImpl: MinimuxerAPI {
    var isrppairing: Bool { IdeviceGateway.shared.isRPPairing }

    var isLoggingEnabled = true

    private var mountTask: Task<Bool, Error>? = nil
    private var lastDocsPath: String? = nil

    func describeError(_ error: MinimuxerError) -> String {
        return error.description
    }
    
    func bindTunnelConfig(_ binding: TunnelConfigBinding) async {
        await IfaceScanner.shared.bindTunnelConfig(binding)
    }
    
    func ready() async throws -> Bool {
        if !(Minimuxer.network.isWifiSatisfied  ||
             Minimuxer.network.isWiredSatisfied ||
             Minimuxer.network.isBridgeSatisfied
        ){
            debugLog("[minimuxer] minimuxer not ready: no network connection")
            throw MinimuxerError.NoConnection
        }

        let deviceIP: String
        do {
            deviceIP = try await DeviceEndpoint.shared.ip()
        } catch {
            debugLog("[minimuxer] minimuxer not ready: device endpoint not initialized")
            throw MinimuxerError.NoVPN
        }
        
        let deviceConnection = testDeviceConnection(ifaddr: deviceIP)
        if !deviceConnection {
            debugLog("[minimuxer] minimuxer not ready: failed to connect to device IP")
            throw MinimuxerError.InvalidVPN
        }

        let ddiMounted = (try? IdeviceGateway.shared.isDDIMounted()) ?? false
        if isrppairing {
            guard ddiMounted else {
                verboseLog(
                    "minimuxer not ready (RSD): " +
                    "dmg=\(ddiMounted) " +
                    "started=\(MuxerService.isListening) "
                )
                throw MinimuxerError.Mount
            }
            return true
        }
        
        let deviceUDID: String? = try? IdeviceGateway.shared.fetchUDID()
        verboseLog(
            "minimuxer status (usbmuxd): " +
            "deviceUDID=\(deviceUDID ?? "nil") " +
            "dmg=\(ddiMounted) " +
            "started=\(MuxerService.isListening) "
        )
        guard deviceUDID != nil else {
            throw MinimuxerError.InvalidPairing(type: "lockdown")
        }
        guard ddiMounted else {
            throw MinimuxerError.Mount
        }
        guard MuxerService.isListening else {
            throw MinimuxerError.MuxerNotListening
        }
        return true
    }

    private func restartMuxerServer() async throws {
        guard !isrppairing else { return }
        
        guard let pairingDict = IdeviceGateway.shared.pairingDataDict else {
            debugLog("[minimuxer] ERROR: Pairing DICT missing...ignoring restart MuxerServer")
            throw MinimuxerError.PairingFile
        }
        verboseLog("[minimuxer] DEBUG: loaded pairing file keys: \(pairingDict.keys)")

        guard let deviceUDID = pairingDict["UDID"] as? String else {
            debugLog("[minimuxer] ERROR: Pairing file missing UDID")
            throw MinimuxerError.PairingFile
        }

        // restart muxer
        MuxerService.stop()
        try await MuxerService.start(udid: deviceUDID)
    }
    
    func start(pairingFile: String, mountPath: String) async throws {
        lastDocsPath = mountPath
        // let idevice initialize its state and set isRPPairing
        try IdeviceGateway.shared.start(pairingFileContent: pairingFile)
        // retarget usbmuxd to our fake usbmuxd server (over network)
        retargetUsbmuxdAddr()
        // start our fake usbmuxd server for lockdown protocol based clients if required
        try await restartMuxerServer()
        
        try await Mounter.shared.mount(docsPath: mountPath)
    }

    private func stopAll() async {
        // Cancel the mount task first, then tear down muxer
        mountTask?.cancel()
        mountTask = nil
        MuxerService.stop()
    }

    func reinitializePairingData(pairingFile: String) async throws {
        verboseLog("[minimuxer] Reinitializing with new pairing file...")
        await stopAll()
        guard let mountPath = lastDocsPath else {
            throw MinimuxerError.Mount
        }
        try await start(pairingFile: pairingFile, mountPath: mountPath)
    }

    func setLogging(_ enabled: Bool) {
        self.isLoggingEnabled = enabled
        IdeviceGateway.shared.setLogging(enabled)
    }
    
    func retargetUsbmuxdAddr() {
        verboseLog("[minimuxer] unsetenv(USBMUXD_SOCKET_ADDRESS)")
        unsetenv(MinimuxerConstants.usbmuxdEnvKey)
        verboseLog("[minimuxer] setenv(USBMUXD_SOCKET_ADDRESS, \(MinimuxerConstants.usbmuxdSocket))")
        setenv(MinimuxerConstants.usbmuxdEnvKey, MinimuxerConstants.usbmuxdSocket, 1)
        let value = String(cString: getenv(MinimuxerConstants.usbmuxdEnvKey))
        verboseLog("[minimuxer] getenv(USBMUXD_SOCKET_ADDRESS) = \(value)")
    }
    
    func fetchUDID() async throws -> String? {
        return try IdeviceGateway.shared.fetchUDID()
    }
    
    func testDeviceConnection(ifaddr: String?) -> Bool {
        guard let ip = ifaddr else { return false }
        
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = isrppairing ? MinimuxerConstants.rsdPort.bigEndian : MinimuxerConstants.lockdowndPort.bigEndian
        inet_pton(AF_INET, ip, &addr.sin_addr)

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let result = poll(&pfd, 1, 100)
        return result > 0 && (pfd.revents & Int16(POLLOUT)) != 0
    }


    func yeetAppAfc(bundleId: String, ipaBytes: Data) throws {
        try IdeviceGateway.shared.yeetAppAfc(bundleId: bundleId, ipaBytes: ipaBytes)
    }

    func installIpa(bundleId: String) throws {
        try IdeviceGateway.shared.installIpa(bundleId: bundleId)
    }

    func removeApp(bundleId: String) throws {
        try IdeviceGateway.shared.removeApp(bundleId: bundleId)
    }

    func debugApp(appId: String) throws {
        try IdeviceGateway.shared.debugApp(appId: appId)
    }

    func attachDebugger(pid: UInt32) throws {
        try IdeviceGateway.shared.debugProcess(pid: pid)
    }

    func installProvisioningProfile(profile: Data) throws {
        try IdeviceGateway.shared.installProvisioningProfile(profile: profile)
    }

    func removeProvisioningProfile(id: String) throws {
        try IdeviceGateway.shared.removeProvisioningProfile(id: id)
    }

    func dumpProfiles(docsPath: String) throws -> String {
        try IdeviceGateway.shared.dumpProfiles(docsPath: docsPath)
    }

    func startAutoMounter(docsPath: String) async {
        lastDocsPath = docsPath
        mountTask?.cancel()
        let task = Task {
            try await Mounter.shared.mount(docsPath: docsPath)
        }
        mountTask = task
        _ = await task.result
    }

    func restart() async throws {
        verboseLog("[minimuxer] Restarting services...")
        guard let pairingData = IdeviceGateway.shared.pairingFileData,
              let pairingFile = String(data: pairingData, encoding: .utf8) else {
            debugLog("[minimuxer] restart: no existing pairing file — cannot restart")
            throw MinimuxerError.PairingFile
        }
        guard let mountPath = lastDocsPath else {
            throw MinimuxerError.Mount
        }
        await stopAll()
        try await start(pairingFile: pairingFile, mountPath: mountPath)
        Minimuxer.network.refreshEndpoint()
    }
}

@inline(__always)
func debugLog(_ text: String) {
    print(text)
}


@inline(__always)
func verboseLog(_ text: String) {
    if Minimuxer.shared.isLoggingEnabled {
        print(text)
    }
}
