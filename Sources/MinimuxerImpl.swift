//
//  Minimuxer.swift
//  Minimuxer
//
//  Created by Magesh K on 4/7/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import RustBridge
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final internal class MinimuxerImpl: MinimuxerAPI {
    
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
    
    func bindTunnelConfig(_ binding: TunnelConfigBinding) {
        IfaceScanner.shared.bindTunnelConfig(binding)
    }
    
    func ready() -> Result<Bool, MinimuxerError> {
        if !(Minimuxer.network.isWifiSatisfied  ||
             Minimuxer.network.isWiredSatisfied ||
             Minimuxer.network.isBridgeSatisfied
        ){
            debugLog("[minimuxer] minimuxer not ready: no network connection")
            return .failure(MinimuxerError.NoConnection)
        }

        let deviceIP: String
        do {
            deviceIP = try DeviceEndpoint.shared.ip()
        } catch {
            debugLog("[minimuxer] minimuxer not ready: device endpoint not initialized")
            return .failure(MinimuxerError.NoVPN)
        }
        
        let deviceConnection = testDeviceConnection(ifaddr: deviceIP)
        if !deviceConnection {
            debugLog("[minimuxer] minimuxer not ready: failed to connect to device IP")
            return .failure(MinimuxerError.InvalidVPN)
        }

        if MuxerService.isrppairing {
            guard MounterService.isReady() else {
                verboseLog(
                    "minimuxer not ready (RSD): " +
                    "dmg=\(MounterService.isReady()) " +
                    "started=\(MuxerService.started) " +
                    "ready=\(MuxerService.usbmuxdReady)"
                )
                return .failure(MinimuxerError.InvalidPairing)
            }
            return .success(true)
        }
        
        let deviceExists: Bool
        do {
            _ = try DeviceService.getFirstDevice()
            deviceExists = true
        } catch {
            deviceExists = false
        }
        guard deviceExists, HeartbeatService.lastBeatSuccessful, MounterService.isReady(), MuxerService.started, MuxerService.usbmuxdReady else {
            verboseLog(
                "minimuxer not ready (usbmuxd): " +
                "dev=\(deviceExists) " +
                "hb=\(HeartbeatService.lastBeatSuccessful) " +
                "dmg=\(MounterService.isReady()) " +
                "started=\(MuxerService.started) " +
                "ready=\(MuxerService.usbmuxdReady)"
            )
            return .failure(MinimuxerError.InvalidPairing)
        }
        
        if #available(iOS 26.4, *) {
            if !IfaceScanner.shared.vpnPatched() {
                debugLog("[minimuxer] WARN: VPN subnet not patched")
            }
        }
        return .success(true)
    }
    
    func setLogging(_ enabled: Bool) {
//        rustBridgeSetDebug(enabled)
//        _rust_bridge_idevice_set_logging(enabled)
        self.isLoggingEnabled = enabled
    }
    
    func reinitializePairingData(pairingFile: String) throws {
        try MuxerService.reinitializePairingData(pairingFile: pairingFile)
    }
    
    func start(pairingFile: String) throws {
        try MuxerService.start(pairingFile: pairingFile)
    }
    
    func retargetUsbmuxdAddr() {
        MuxerService.retargetUsbmuxdAddr()
    }
    
    func fetchUDID() -> String? {
        verboseLog("[minimuxer] Getting UDID for first device")
        guard MuxerService.started else {
            debugLog("[minimuxer] ERROR: minimuxer has not started!")
            return nil
        }
        let udid: String?
        if MuxerService.isrppairing {
            udid = IdeviceGateway.shared.fetchUDID()
        } else {
            udid = (try? DeviceService.getFirstDevice())?.getUDID()
        }
        
        if let udid = udid {
            verboseLog("[minimuxer] UDID: \(udid)")
        } else {
            debugLog("[minimuxer] ERROR: Failed to get UDID")
        }
        return udid
    }
    
    func testDeviceConnection(ifaddr: String?) -> Bool {
        guard let ip = ifaddr else { return false }
        
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = MuxerService.isrppairing ? MinimuxerConstants.rsdPort.bigEndian : MinimuxerConstants.lockdowndPort.bigEndian
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
        try Install.yeetAppAfc(bundleId: bundleId, ipaBytes: ipaBytes)
    }
    
    func installIpa(bundleId: String) throws {
        try Install.installIpa(bundleId: bundleId)
    }
    
    func removeApp(bundleId: String) throws {
        try Install.removeApp(bundleId: bundleId)
    }
    
    func debugApp(appId: String) throws {
        try JIT.debugApp(appId: appId)
    }
    
    func attachDebugger(pid: UInt32) throws {
        try JIT.attachDebugger(pid: pid)
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
    
    func installProvisioningProfile(profile: Data) throws {
        try Provision.installProvisioningProfile(profile: profile)
    }
    
    func removeProvisioningProfile(id: String) throws {
        try Provision.removeProvisioningProfile(id: id)
    }
    
    func dumpProfiles(docsPath: String) throws -> String {
        return try Provision.dumpProfiles(docsPath: docsPath)
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
