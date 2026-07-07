//
//  Minimuxer.swift
//  Minimuxer
//
//  Created by Magesh K on 4/7/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation

private enum MinimuxerStatus{
    case started, inprogress, stopped
}

final internal class MinimuxerImpl: MinimuxerAPI {
    private actor State {
        var status: MinimuxerStatus = .stopped
        var mountTask: Task<Bool, Error>? = nil
        var lastDocsPath: String? = nil
        
        func with<T>(_ body: (isolated State) throws -> T) rethrows -> T {
            try body(self)
        }
    }
    private let state = State()
    
    var isrppairing: Bool { IdeviceGateway.shared.isRPPairing }
    
    var isLoggingEnabled = true


    func describeError(_ error: MinimuxerError) -> String {
        return error.description
    }
    
    func bindTunnelConfig(_ binding: TunnelConfigBinding) async {
        await IfaceScanner.shared.bindTunnelConfig(binding)
    }
    
    var isReady: Result<Bool, MinimuxerError> {
        get async {
            // check connection status first
            if !(Minimuxer.network.isWifiSatisfied  ||
                 Minimuxer.network.isWiredSatisfied ||
                 Minimuxer.network.isBridgeSatisfied
            ){
                debugLog("[minimuxer] minimuxer not ready: no network connection")
                return .failure(.noConnection("No wifi, wired or bridge interface satisfied"))
            }

            // check VPN Availability for all modes
            let net = Minimuxer.network
            let uTunPresent = net.isUTunAvailable
            if !uTunPresent {
                debugLog("[minimuxer] minimuxer not ready: no utun interface found")
                return .failure(.noVPN("No utun interface detected — LocalDevVPN is not connected"))
            }

            // check iKEv2 too if in lockdown mode and ios >= 26.4
            if !isrppairing && !net.isIKEv2IPSecAvailable {
                if #available(iOS 26.4, *) {
                    debugLog("[minimuxer] minimuxer not ready: no ipsec interface (required for lockdown on iOS 16.4+)")
                    return .failure(.invalidVPN("utun is present but no ipsec/IKEv2 interface found — LocalDevVPN may not support the lockdown protocol on iOS 26.4+"))
                }
            }

            // then check if device is ready
            let deviceIP: String
            do {
                deviceIP = try await DeviceEndpoint.shared.ip()
            } catch {
                debugLog("[minimuxer] minimuxer not ready: device IP not available despite utun being present")
                return .failure(.invalidVPN("VPN tunnel (utun) is up but device IP is unreachable — VPN may not be routing device traffic correctly. Cause: \(error.localizedDescription)"))
            }
            
            let deviceConnection = testDeviceConnection(ifaddr: deviceIP)
            if !deviceConnection {
                debugLog("[minimuxer] minimuxer not ready: failed to connect to device IP")
                return .failure(.invalidVPN("VPN tunnel is up and device IP \(deviceIP) is known, but TCP port poll failed — device may be unreachable on this interface"))
            }


            let activeProtocol: MinimuxerProtocol = isrppairing ? .rppairing : .lockdown

            let ddiMounted: Bool
            do {
                ddiMounted = try runIdeviceCheckingVPN("while checking DDI mount status", fallback: false) {
                    try IdeviceGateway.shared.isDDIMounted()
                }
            } catch let err as MinimuxerError {
                return .failure(err)
            }

            if isrppairing {
                guard ddiMounted else {
                    let msg = "dmg=\(ddiMounted) started=\(MuxerService.isListening)"
                    verboseLog("minimuxer not ready (RSD): \(msg)")
                    return .failure(.mount(protocol: activeProtocol, reason: msg))
                }
                return .success(true)
            }

            let deviceUDID: String?
            do {
                deviceUDID = try runIdeviceCheckingVPN("while fetching device UDID", fallback: nil) {
                    try IdeviceGateway.shared.fetchUDID()
                }
            } catch let err as MinimuxerError {
                return .failure(err)
            }

            verboseLog(
                "minimuxer status (usbmuxd): " +
                "deviceUDID=\(deviceUDID ?? "nil") " +
                "dmg=\(ddiMounted) " +
                "started=\(MuxerService.isListening) "
            )
            guard deviceUDID != nil else {
                return .failure(.invalidPairing(protocol: activeProtocol, reason: "Lockdown UDID not found"))
            }
            guard ddiMounted else {
                return .failure(.mount(protocol: activeProtocol, reason: "DeveloperDiskImage is not mounted"))
            }
            guard MuxerService.isListening else {
                return .failure(.muxerNotListening("Usbmuxd fake server is not listening"))
            }
            return .success(true)
        }
    } 

    @inline(__always)
    private func runIdeviceCheckingVPN<T>(_ context: String, fallback: T, action: () throws -> T) throws(MinimuxerError) -> T {
        do {
            return try action()
        } catch let err as IdeviceGatewayError {
            if case .connectionFailed(let reason) = err,
               reason.lowercased().contains("broken pipe") || reason.lowercased().contains("brokenpipe") {
                throw MinimuxerError.noVPN("VPN tunnel connection severed \(context). Cause: \(reason)")
            }
            return fallback
        } catch {
            return fallback
        }
    }
    
    // This is required since we want to dissociate the caller priority from what rust internally uses so that
    // thread checker doesn't complain inversion of priority (ex: if caller was Task instantiated from MainThread,
    // then it is of .userInitiated priority by default, but our rust tokio threads are at .background priority
    //
    // NOTE: For now this wrapping is only required for IdeviceGateway apis that do device services like fetchUDID, install etc
    //
    @inline(__always)
    private func matchingPriority<T: Sendable>(priority: TaskPriority = .medium, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await Task.detached(priority: priority) {
            try await body()
        }.value
    }

    private func restartMuxerServer() async throws {
        guard !isrppairing else { return }
        // restartMuxerServer only applies to the lockdown protocol path
        guard let pairingDict = IdeviceGateway.shared.pairingDataDict else {
            debugLog("[minimuxer] ERROR: Pairing DICT missing...ignoring restart MuxerServer")
            throw MinimuxerError.pairingFile(protocol: .lockdown, reason: "Pairing dictionary is missing in gateway")
        }
        verboseLog("[minimuxer] DEBUG: loaded pairing file keys: \(pairingDict.keys)")

        guard let deviceUDID = pairingDict["UDID"] as? String else {
            debugLog("[minimuxer] ERROR: Pairing file missing UDID")
            throw MinimuxerError.pairingFile(protocol: .lockdown, reason: "Pairing file is missing UDID value")
        }

        // restart muxer
        MuxerService.stop()
        try await MuxerService.start(udid: deviceUDID)
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
    
    
    func start(pairingFile: String, mountPath: String) async throws {
        // actor serialization scope
        try await state.with{
            $0.status = .inprogress     // mark inprogress
            $0.lastDocsPath = mountPath // record the mountPath
        }
        // let idevice initialize its state and set isRPPairing
        try IdeviceGateway.shared.start(pairingFileContent: pairingFile)
        // retarget usbmuxd to our fake usbmuxd server (over network)
        retargetUsbmuxdAddr()
        // start our fake usbmuxd server for lockdown protocol based clients if required
        try await restartMuxerServer()
        
        try await matchingPriority{
            try await Mounter.shared.mount(docsPath: mountPath)
        }
        // mark ready!
        try await state.with{
            $0.status = .started
        }
    }

    func stop() async {
        // actor serialization scope
        try await state.with{
            $0.status = .inprogress // mark inprogress
            $0.mountTask?.cancel()  // cancel the task
        }
        try await state.with{
            $0.status = .inprogress
            $0.mountTask = nil
        }
        MuxerService.stop()
        // mark ready!
        try await state.with{
            $0.status = .stopped
        }
    }
    
    func restart() async throws {
        verboseLog("[minimuxer] Restarting services...")
        let activeProtocol: MinimuxerProtocol = isrppairing ? .rppairing : .lockdown
        guard let pairingData = IdeviceGateway.shared.pairingFileData,
              let pairingFile = String(data: pairingData, encoding: .utf8) else {
            debugLog("[minimuxer] restart: no existing pairing file — cannot restart")
            throw MinimuxerError.pairingFile(protocol: activeProtocol, reason: "No existing pairing file found in gateway during restart")
        }
        guard let mountPath = await state.lastDocsPath else {
            throw MinimuxerError.mount(protocol: activeProtocol, reason: "lastDocsPath is nil during restart")
        }
        await stop()
        try await start(pairingFile: pairingFile, mountPath: mountPath)
        Minimuxer.network.refreshEndpoint()
    }
    
    func mountDDI(docsPath: String) async throws -> Bool {
        // actor serialization scope
        await state.with{
            $0.lastDocsPath = docsPath  // record the mountPath
            $0.mountTask?.cancel()      // cancel the task
        }
        let task = Task.detached(priority: .medium) {
            try await Mounter.shared.mount(docsPath: docsPath)
        }
        await state.with{
            $0.mountTask = task
        }
        return try await task.value
    }

    func reinitializePairingData(pairingFile: String) async throws {
        verboseLog("[minimuxer] Reinitializing with new pairing file...")
        await stop()
        guard let mountPath = await state.lastDocsPath else {
            let activeProtocol: MinimuxerProtocol = isrppairing ? .rppairing : .lockdown
            throw MinimuxerError.mount(protocol: activeProtocol, reason: "start() should be invoked before requesting pairing data reinitialization. cause: lastDocsPath is nil")
        }
        try await start(pairingFile: pairingFile, mountPath: mountPath)
    }

    func fetchUDID() async throws -> String? {
        try await matchingPriority{
            try IdeviceGateway.shared.fetchUDID()
        }
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


    func yeetAppAfc(bundleId: String, ipaBytes: Data) async throws {
        try await matchingPriority{
            try IdeviceGateway.shared.yeetAppAfc(bundleId: bundleId, ipaBytes: ipaBytes)
        }
    }

    func installIpa(bundleId: String) async throws {
        try await matchingPriority{
            try IdeviceGateway.shared.installIpa(bundleId: bundleId)
        }
    }

    func removeApp(bundleId: String) async throws {
        try await matchingPriority{
            try IdeviceGateway.shared.removeApp(bundleId: bundleId)
        }
    }

    func debugApp(appId: String) async throws {
        try await matchingPriority{
            try IdeviceGateway.shared.debugApp(appId: appId)
        }
    }

    func attachDebugger(pid: UInt32) async throws {
        try await matchingPriority{
            try IdeviceGateway.shared.debugProcess(pid: pid)
        }
    }

    func installProvisioningProfile(profile: Data) async throws {
        try await matchingPriority{
            try IdeviceGateway.shared.installProvisioningProfile(profile: profile)
        }
    }

    func removeProvisioningProfile(id: String) async throws {
        try await matchingPriority{
            try IdeviceGateway.shared.removeProvisioningProfile(id: id)
        }
    }

    func dumpProfiles(docsPath: String) async throws -> String {
        try await matchingPriority{
            try IdeviceGateway.shared.dumpProfiles(docsPath: docsPath)
        }
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
