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
    
    private actor MutableState {
        var continuation: CheckedContinuation<Void, Error>?
        var docsPath: String?
        
        func setDocsPath(_ path: String) {
            self.docsPath = path
        }
        
        func registerContinuation(_ co: CheckedContinuation<Void, Error>) throws {
            if continuation != nil {
                throw MinimuxerError.RestartAlreadyInProgressError
            }
            self.continuation = co
        }
        
        func consumeContinuation() -> CheckedContinuation<Void, Error>? {
            let co = continuation
            continuation = nil
            return co
        }
    }
    
    private let state = MutableState()
    
    var isLoggingEnabled = true
    var onBackgroundError: ((Error) async -> Void)?

    func describeError(_ error: MinimuxerError) -> String {
        return error.description
    }
    
    func bindTunnelConfig(_ binding: TunnelConfigBinding) async {
        await IfaceScanner.shared.bindTunnelConfig(binding)
    }
    
    func ready() -> Result<Bool, MinimuxerError> {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Bool, MinimuxerError>!
        Task {
            result = await readyAsync()
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    private func readyAsync() async -> Result<Bool, MinimuxerError> {
        if !(Minimuxer.network.isWifiSatisfied  ||
             Minimuxer.network.isWiredSatisfied ||
             Minimuxer.network.isBridgeSatisfied
        ){
            debugLog("[minimuxer] minimuxer not ready: no network connection")
            return .failure(MinimuxerError.NoConnection)
        }

        let deviceIP: String
        do {
            deviceIP = try await DeviceEndpoint.shared.ip()
        } catch {
            debugLog("[minimuxer] minimuxer not ready: device endpoint not initialized")
            return .failure(MinimuxerError.NoVPN)
        }
        
        let deviceConnection = testDeviceConnection(ifaddr: deviceIP)
        if !deviceConnection {
            debugLog("[minimuxer] minimuxer not ready: failed to connect to device IP")
            return .failure(MinimuxerError.InvalidVPN)
        }

        if isrppairing {
            guard MounterService.isReady else {
                verboseLog(
                    "minimuxer not ready (RSD): " +
                    "dmg=\(MounterService.isReady) " +
                    "started=\(MuxerService.isReady) "
                )
                return .failure(MinimuxerError.InvalidPairing)
            }
            return .success(true)
        }
        
        let deviceUDID: String? = try? IdeviceGateway.shared.fetchUDID()
        verboseLog(
            "minimuxer status (usbmuxd): " +
            "deviceUDID=\(deviceUDID ?? "nil") " +
            "dmg=\(MounterService.isReady) " +
            "started=\(MuxerService.isReady) "
        )
        guard deviceUDID != nil,
            MounterService.isReady, 
            MuxerService.isReady
        else {
            return .failure(MinimuxerError.InvalidPairing)
        }
        
        if #available(iOS 26.4, *) {
            if await !IfaceScanner.shared.vpnPatched() {
                debugLog("[minimuxer] WARN: VPN subnet not patched")
            }
        }
        return .success(true)
    }

    private func restartMuxerServer(pairingFile: String) throws {
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
        try MuxerService.stop()
        try MuxerService.start(udid: deviceUDID)
    }
    
    func start(pairingFile: String) throws {
        // let idevice initialize its state and set isRPPairing
        try IdeviceGateway.shared.start(pairingFileContent: pairingFile)
        // retarget usbmuxd to our fake usbmuxd server (over network)
        retargetUsbmuxdAddr()
        // start our fake usbmuxd server for lockdown protocol based clients if required
        try restartMuxerServer(pairingFile: pairingFile)
    }
    
    func setLogging(_ enabled: Bool) {
        self.isLoggingEnabled = enabled
        IdeviceGateway.shared.setLogging(enabled)
    }
    
    func reinitializePairingData(pairingFile: String) throws {
        try restartMuxerServer(pairingFile: pairingFile)
    }
    
    func retargetUsbmuxdAddr() {
        verboseLog("[minimuxer] unsetenv(USBMUXD_SOCKET_ADDRESS)")
        unsetenv(MinimuxerConstants.usbmuxdEnvKey)
        verboseLog("[minimuxer] setenv(USBMUXD_SOCKET_ADDRESS, \(MinimuxerConstants.usbmuxdSocket))")
        setenv(MinimuxerConstants.usbmuxdEnvKey, MinimuxerConstants.usbmuxdSocket, 1)
        let value = String(cString: getenv(MinimuxerConstants.usbmuxdEnvKey))
        verboseLog("[minimuxer] getenv(USBMUXD_SOCKET_ADDRESS) = \(value)")
    }
    
    func fetchUDID() throws -> String? {
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
        await state.setDocsPath(docsPath)
        await MounterService.startAutoMounter(docsPath: docsPath)
    }
    
    func restart() async throws {
        verboseLog("[minimuxer] Restarting services...")
        
        try await withCheckedThrowingContinuation { (co: CheckedContinuation<Void, Error>) in
            Task {
                do {
                    try await state.registerContinuation(co)
                    
                    MounterService.dmgMounted = false
                    await HeartbeatService.stop()
                    
                    if let docsPath = await state.docsPath {
                        await MounterService.startAutoMounter(docsPath: docsPath)
                    }
                    
                    Minimuxer.network.refreshEndpoint()
                } catch {
                    co.resume(throwing: error)
                }
            }
        }
    }
    
    func checkAndNotify(_ status: RestartStatus) async {
        switch status {
            case .ready:
                if case .success(let isReady) = ready(), isReady {
                    if let co = await state.consumeContinuation() {
                        co.resume(returning: ())
                    }
                }
            case .failed(let component, let error):
                if let co = await state.consumeContinuation() {
                    co.resume(throwing: error)
                } else {
                    let wrappedError = MinimuxerServiceError(component: component, error: error)
                    await onBackgroundError?(wrappedError)
                }
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
