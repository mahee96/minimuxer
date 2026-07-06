//
//  Minimuxer.swift
//  Minimuxer
//
//  Created by Magesh K on 4/7/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation

public struct PairingInfo {
    public let dictionary: [String: Any]
    public let xmlData: Data
}

final internal class MinimuxerImpl: MinimuxerAPI {
    var isrppairing: Bool { isRpPairing }
    
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
    
    var isRpPairing: Bool = false
    private var pairingInfo: PairingInfo? = nil
    
    func getPairingInfo() -> PairingInfo? {
        return pairingInfo
    }
    
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
        
        let deviceUDID = (try? IdeviceGateway.shared.fetchUDID())
        verboseLog(
            "minimuxer status (usbmuxd): " +
            "devUDID=\(deviceUDID ?? "nil") " +
            // "hb=\(HeartbeatService.lastBeatSuccessful) " +
            "dmg=\(MounterService.isReady()) " +
            "started=\(MuxerService.started) " +
            "ready=\(MuxerService.usbmuxdReady)"
        )
//        guard deviceUDID != nil, HeartbeatService.lastBeatSuccessful, MounterService.isReady(), MuxerService.started, MuxerService.usbmuxdReady else {
//            return .failure(MinimuxerError.InvalidPairing)
//        }
        
        if #available(iOS 26.4, *) {
            if await !IfaceScanner.shared.vpnPatched() {
                debugLog("[minimuxer] WARN: VPN subnet not patched")
            }
        }
        return .success(true)
    }
    
    func setLogging(_ enabled: Bool) {
        self.isLoggingEnabled = enabled
    }
    
    func reinitializePairingData(pairingFile: String) throws {
        guard let pairingData = pairingFile.data(using: .utf8),
              let pairingDict = try? PropertyListSerialization.propertyList(from: pairingData, options: [], format: nil) as? [String: Any]
        else {
            debugLog("[minimuxer] ERROR: Failed to parse pairing file")
            throw MinimuxerError.PairingFile
        }

        verboseLog("[minimuxer] DEBUG: loaded pairing file keys: \(pairingDict.keys)")

        if let _ = pairingDict["private_key"] as? Data {
            verboseLog("[minimuxer] INFO: RPPairing file detected")
            isRpPairing = true
        } else if let _ = pairingDict["UDID"] as? String {
            verboseLog("[minimuxer] INFO: Lockdown pairing file detected")
            isRpPairing = false
        } else {
            debugLog("[minimuxer] ERROR: Pairing file missing UDID")
            throw MinimuxerError.PairingFile
        }

        var cleanPairingDict = pairingDict
        cleanPairingDict.removeValue(forKey: "UDID")

        guard let pairingXml = try? PropertyListSerialization.data(fromPropertyList: cleanPairingDict, format: .xml, options: 0) else {
            debugLog("[minimuxer] ERROR: Failed to serialize clean pairing file")
            throw MinimuxerError.PairingFile
        }

        self.pairingInfo = PairingInfo(dictionary: pairingDict, xmlData: pairingXml)

        if isrppairing {
            try IdeviceGateway.shared.start(pairingFileContent: pairingFile)
        }
    }
    
    func start(pairingFile: String) throws {
        // parse and update pairing file
        try reinitializePairingData(pairingFile: pairingFile)
        // retarget usbmuxd to our fake server
        retargetUsbmuxdAddr()
        // start our fake usbmuxd server for lockdown protocol based clients
        if !isrppairing {
            try MuxerService.start()
        }
        try IdeviceGateway.shared.start(pairingFileContent: pairingFile)
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
        verboseLog("[minimuxer] Getting UDID for first device")
        let udid = try IdeviceGateway.shared.fetchUDID()
        verboseLog("[minimuxer] Device UDID = \(udid ?? "nil")")
        return udid
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
