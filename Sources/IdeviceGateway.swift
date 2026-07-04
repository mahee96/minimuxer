//
//  IdeviceGateway.swift
//  SideStore
//
//  Created by Magesh K on 05/07/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import IDevice
#if canImport(Darwin)
import Darwin
#endif

public enum IdeviceGatewayError: LocalizedError {
    case invalidPairingFile
    case connectionFailed(String)
    case serviceError(String)
    case noConnection

    public var errorDescription: String? {
        switch self {
        case .invalidPairingFile:
            return "The pairing file is invalid or missing required keys."
        case .connectionFailed(let reason):
            return "Failed to connect to device: \(reason)"
        case .serviceError(let reason):
            return "Service operation failed: \(reason)"
        case .noConnection:
            return "No connection to the device."
        }
    }
}

public final class IdeviceGateway {
    public static let shared = IdeviceGateway()

    private var pairingFile: OpaquePointer? = nil
    private var adapter: OpaquePointer? = nil
    private var handshake: OpaquePointer? = nil
    private var deviceIP: String = "10.7.0.1"
    private var isRPPairing: Bool = false

    private init() {}

    deinit {
        cleanup()
    }

    private func cleanup() {
        if let handshake = handshake {
            rsd_handshake_free(handshake)
            self.handshake = nil
        }
        if let adapter = adapter {
            adapter_free(adapter)
            self.adapter = nil
        }
        if let pairingFile = pairingFile {
            rp_pairing_file_free(pairingFile)
            self.pairingFile = nil
        }
    }

    public func setDeviceIP(_ ip: String) {
        self.deviceIP = ip
        // Invalidate current cached connections
        if handshake != nil {
            rsd_handshake_free(handshake)
            self.handshake = nil
        }
        if adapter != nil {
            adapter_free(adapter)
            self.adapter = nil
        }
    }

    public func setLogging(_ enabled: Bool) {
        idevice_init_logger(enabled ? IdeviceLogLevel(rawValue: 4) : IdeviceLogLevel(rawValue: 0), IdeviceLogLevel(rawValue: 0), nil)
    }

    public func start(pairingFileContent: String) throws {
        cleanup()

        guard let data = pairingFileContent.data(using: .utf8) else {
            throw IdeviceGatewayError.invalidPairingFile
        }

        // Check if pairing file is RPPairing
        if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            if plist["private_key"] != nil {
                isRPPairing = true
            }
        }

        if isRPPairing {
            try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                if let baseAddress = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                    let err = rp_pairing_file_from_bytes(baseAddress, UInt(data.count), &pairingFile)
                    if err != nil {
                        throw IdeviceGatewayError.invalidPairingFile
                    }
                }
            }
            try ensureRPConnection()
        } else {
            // Traditional usbmuxd / lockdown connection path
            // For pre-iOS 17 devices, a default connection can be established without RPPairing tunnel
            isRPPairing = false
        }
    }

    private func ensureRPConnection() throws {
        if adapter != nil && handshake != nil {
            return
        }

        guard let pairingFile = pairingFile else {
            throw IdeviceGatewayError.invalidPairingFile
        }

        // Standard RPPairing socket address
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(49152).bigEndian
        addr.sin_addr.s_addr = inet_addr(deviceIP)

        let hostname = "minimuxer"
        var err: UnsafeMutablePointer<IdeviceFfiError>? = nil

        try hostname.withCString { hostPtr in
            withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    err = tunnel_create_rppairing(
                        sockaddrPtr,
                        socklen_t(MemoryLayout<sockaddr_in>.size),
                        hostPtr,
                        pairingFile,
                        nil,
                        nil,
                        &adapter,
                        &handshake
                    )
                }
            }
        }

        if let err = err {
            defer { idevice_error_free(err) }
            throw IdeviceGatewayError.connectionFailed("Tunnel creation failed")
        }
    }

    public func fetchUDID() -> String? {
        if isRPPairing {
            do {
                try ensureRPConnection()
            } catch {
                return nil
            }
            guard let handshake = handshake else { return nil }
            var uuidPtr: UnsafeMutablePointer<Int8>? = nil
            let err = rsd_get_uuid(handshake, &uuidPtr)
            if err == nil, let ptr = uuidPtr {
                 let uuid = String(cString: ptr)
                 idevice_string_free(ptr)
                 return uuid
            }
            return nil
        } else {
            var conn: OpaquePointer? = nil
            var err = idevice_usbmuxd_new_default_connection(0, &conn)
            if err == nil, let conn = conn {
                 defer { idevice_usbmuxd_connection_free(conn) }
                 var devices: UnsafeMutablePointer<OpaquePointer?>? = nil
                 var count: Int32 = 0
                 err = idevice_usbmuxd_get_devices(conn, &devices, &count)
                 if err == nil, count > 0, let devicesPtr = devices, let firstDev = devicesPtr.pointee {
                     if let udidPtr = idevice_usbmuxd_device_get_udid(firstDev) {
                         let udid = String(cString: udidPtr)
                         idevice_string_free(udidPtr)
                         return udid
                     }
                 }
            }
            return nil
        }
    }

    public func installProvisioningProfile(profile: Data) throws {
        if isRPPairing {
            try ensureRPConnection()
            var client: OpaquePointer? = nil
            let err = misagent_connect_rsd(adapter, handshake, &client)
            if let err = err {
                defer { idevice_error_free(err) }
                throw IdeviceGatewayError.serviceError("Failed to connect to misagent")
            }
             defer { misagent_client_free(client) }
 
             try profile.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                 if let baseAddress = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                     let installErr = misagent_install(client, baseAddress, profile.count)
                     if let installErr = installErr {
                         defer { idevice_error_free(installErr) }
                         throw IdeviceGatewayError.serviceError("Failed to install profile")
                     }
                 }
             }
        } else {
            throw IdeviceGatewayError.serviceError("Traditional usbmuxd path is not implemented for misagent (use VPN/RPPairing).")
        }
    }

    public func removeProvisioningProfile(id: String) throws {
        if isRPPairing {
            try ensureRPConnection()
            var client: OpaquePointer? = nil
            let err = misagent_connect_rsd(adapter, handshake, &client)
            if let err = err {
                defer { idevice_error_free(err) }
                throw IdeviceGatewayError.serviceError("Failed to connect to misagent")
            }
             defer { misagent_client_free(client) }

            try id.withCString { idPtr in
                let removeErr = misagent_remove(client, idPtr)
                if let removeErr = removeErr {
                    defer { idevice_error_free(removeErr) }
                    throw IdeviceGatewayError.serviceError("Failed to remove profile")
                }
            }
        }
    }

    public func removeApp(bundleId: String) throws {
        if isRPPairing {
            try ensureRPConnection()
             var client: OpaquePointer? = nil
             let err = installation_proxy_connect_rsd(adapter, handshake, &client)
             if let err = err {
                 defer { idevice_error_free(err) }
                 throw IdeviceGatewayError.serviceError("Failed to connect to instproxy")
             }
             defer { installation_proxy_client_free(client) }
 
             try bundleId.withCString { bundleIdPtr in
                 let uninstallErr = installation_proxy_uninstall(client, bundleIdPtr, nil)
                 if let uninstallErr = uninstallErr {
                     defer { idevice_error_free(uninstallErr) }
                     throw IdeviceGatewayError.serviceError("Failed to uninstall app")
                 }
             }
        }
    }

    public func yeetAppAfc(bundleId: String, ipaBytes: Data) throws {
        if isRPPairing {
            try ensureRPConnection()
             var client: OpaquePointer? = nil
             let err = afc_client_connect_rsd(adapter, handshake, &client)
             if let err = err {
                 defer { idevice_error_free(err) }
                 throw IdeviceGatewayError.serviceError("Failed to connect to AFC client")
             }
             defer { afc_client_free(client) }
 
            // Ensure directory
            let stagingDir = "PublicStaging"
            _ = stagingDir.withCString { dirPtr in
                afc_make_directory(client, dirPtr)
            }
            let bundleDir = "\(stagingDir)/\(bundleId)"
            _ = bundleDir.withCString { dirPtr in
                afc_make_directory(client, dirPtr)
            }
 
             let path = "\(bundleDir)/app.ipa"
             var fileHandle: OpaquePointer? = nil
             let openErr = path.withCString { pathPtr in
                 afc_file_open(client, pathPtr, AfcFopenMode(rawValue: 4), &fileHandle) // WrOnly/Wr mode
             }
             if let openErr = openErr {
                 defer { idevice_error_free(openErr) }
                 throw IdeviceGatewayError.serviceError("Failed to open remote AFC file")
             }
             defer { afc_file_close(fileHandle) }
 
             try ipaBytes.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                 if let baseAddress = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                     let writeErr = afc_file_write(fileHandle, baseAddress, ipaBytes.count)
                     if let writeErr = writeErr {
                         defer { idevice_error_free(writeErr) }
                         throw IdeviceGatewayError.serviceError("Failed to write to AFC file")
                     }
                 }
             }
        }
    }

    public func installIpa(bundleId: String) throws {
        if isRPPairing {
            try ensureRPConnection()
             var client: OpaquePointer? = nil
             let err = installation_proxy_connect_rsd(adapter, handshake, &client)
             if let err = err {
                 defer { idevice_error_free(err) }
                 throw IdeviceGatewayError.serviceError("Failed to connect to instproxy")
             }
             defer { installation_proxy_client_free(client) }
 
             let path = "PublicStaging/\(bundleId)/app.ipa"
             try path.withCString { pathPtr in
                 let installErr = installation_proxy_install(client, pathPtr, nil)
                 if let installErr = installErr {
                     defer { idevice_error_free(installErr) }
                     throw IdeviceGatewayError.serviceError("Failed to install IPA")
                 }
             }
        }
    }

    public func debugApp(appId: String) throws {
        if isRPPairing {
            try ensureRPConnection()
            var client: OpaquePointer? = nil
            let err = debug_proxy_connect_rsd(adapter, handshake, &client)
            if let err = err {
                defer { idevice_error_free(err) }
                throw IdeviceGatewayError.serviceError("Failed to connect to debug proxy")
            }
            defer { debug_proxy_free(client) }
        }
    }

    public func debugProcess(pid: UInt32) throws {
        if isRPPairing {
            try ensureRPConnection()
            var client: OpaquePointer? = nil
            let err = debug_proxy_connect_rsd(adapter, handshake, &client)
            if let err = err {
                defer { idevice_error_free(err) }
                throw IdeviceGatewayError.serviceError("Failed to connect to debug proxy")
            }
            defer { debug_proxy_free(client) }

            let commands = [("vAttach", [String(format: "%02X", pid)]), ("D", [])]
            for (name, args) in commands {
                try name.withCString { namePtr in
                    var argPtrs = args.map { UnsafePointer<Int8>(strdup($0)) }
                    defer {
                        for ptr in argPtrs {
                            free(UnsafeMutablePointer(mutating: ptr))
                        }
                    }
                    
                    let cmdHandle = debugserver_command_new(namePtr, &argPtrs, UInt(argPtrs.count))
                    if let cmdHandle = cmdHandle {
                        defer { debugserver_command_free(cmdHandle) }
                        var response: UnsafeMutablePointer<Int8>? = nil
                        let sendErr = debug_proxy_send_command(client, cmdHandle, &response)
                        if let sendErr = sendErr {
                            defer { idevice_error_free(sendErr) }
                            throw IdeviceGatewayError.serviceError("Failed to send command to debug proxy: \(name)")
                        }
                        if let response = response {
                            free(response)
                        }
                    }
                }
            }
        }
    }

    public func dumpProfiles(docsPath: String) throws -> String {
        if isRPPairing {
            try ensureRPConnection()
            var client: OpaquePointer? = nil
            let err = misagent_connect_rsd(adapter, handshake, &client)
            if let err = err {
                defer { idevice_error_free(err) }
                throw IdeviceGatewayError.serviceError("Failed to connect to misagent")
            }
            defer { misagent_client_free(client) }

            var outProfiles: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>? = nil
            var outProfilesLen: UnsafeMutablePointer<Int>? = nil
            var outCount: Int = 0

            let copyErr = misagent_copy_all(client, &outProfiles, &outProfilesLen, &outCount)
            if let copyErr = copyErr {
                defer { idevice_error_free(copyErr) }
                throw IdeviceGatewayError.serviceError("Failed to copy profiles from misagent")
            }

            let path = docsPath.hasPrefix("file://") ? String(docsPath.dropFirst(7)) : docsPath
            let dumpDir = "\(path)/PROVISION"
            try? FileManager.default.createDirectory(atPath: dumpDir, withIntermediateDirectories: true)

            if let outProfiles = outProfiles, let outProfilesLen = outProfilesLen, outCount > 0 {
                let xmlPrefix = "<?xml version=".data(using: .utf8)!
                let xmlSuffix = "</plist>".data(using: .utf8)!

                for i in 0..<outCount {
                    guard let profPtr = outProfiles[i] else { continue }
                    let len = outProfilesLen[i]
                    let profileData = Data(bytes: profPtr, count: len)

                    guard let prefixRange = profileData.range(of: xmlPrefix) else { continue }
                    guard let suffixRange = profileData.range(of: xmlSuffix, options: [], in: prefixRange.lowerBound..<profileData.count) else { continue }

                    let plistBytes = profileData.subdata(in: prefixRange.lowerBound..<suffixRange.upperBound)

                    if let innerPlist = try? PropertyListSerialization.propertyList(from: plistBytes, options: [], format: nil) as? [String: Any],
                       let uuid = innerPlist["UUID"] as? String {
                        try? profileData.write(to: URL(fileURLWithPath: "\(dumpDir)/\(uuid).mobileprovision"))
                        try? plistBytes.write(to: URL(fileURLWithPath: "\(dumpDir)/\(uuid).plist"))
                    } else {
                        try? profileData.write(to: URL(fileURLWithPath: "\(dumpDir)/unknown_\(i).mobileprovision"))
                    }
                }
                misagent_free_profiles(outProfiles, outProfilesLen, outCount)
            }
            return dumpDir
        }
        return ""
    }

    public func mountPersonalizedDdi(image: Data, trustcache: Data, manifest: Data) throws {
        if isRPPairing {
            try ensureRPConnection()
            
            // Connect to lockdownd to get UniqueChipID
            var lockdownClient: OpaquePointer? = nil
            let ldErr = lockdownd_connect_rsd(adapter, handshake, &lockdownClient)
            if let ldErr = ldErr {
                defer { idevice_error_free(ldErr) }
                throw IdeviceGatewayError.serviceError("Failed to connect to lockdownd")
            }
            defer { lockdownd_client_free(lockdownClient) }

            var plistVal: plist_t? = nil
            let valErr = lockdownd_get_value(lockdownClient, "UniqueChipID", nil, &plistVal)
            if let valErr = valErr {
                defer { idevice_error_free(valErr) }
                throw IdeviceGatewayError.serviceError("Failed to get UniqueChipID")
            }
            defer { plist_free(plistVal) }

            var chipID: UInt64 = 0
            plist_get_uint_val(plistVal, &chipID)

            // Connect to image mounter
            var mounterClient: OpaquePointer? = nil
            let mntErr = image_mounter_connect_rsd(adapter, handshake, &mounterClient)
            if let mntErr = mntErr {
                defer { idevice_error_free(mntErr) }
                throw IdeviceGatewayError.serviceError("Failed to connect to image mounter")
            }
            defer { image_mounter_free(mounterClient) }

            // Mount the personalized DDI
            try image.withUnsafeBytes { imgBuf in
                try trustcache.withUnsafeBytes { tcBuf in
                    try manifest.withUnsafeBytes { manBuf in
                        let mountErr = image_mounter_mount_personalized_rsd(
                            mounterClient,
                            adapter,
                            handshake,
                            imgBuf.bindMemory(to: UInt8.self).baseAddress,
                            image.count,
                            tcBuf.bindMemory(to: UInt8.self).baseAddress,
                            trustcache.count,
                            manBuf.bindMemory(to: UInt8.self).baseAddress,
                            manifest.count,
                            nil,
                            chipID
                        )
                         if let mountErr = mountErr {
                             defer { idevice_error_free(mountErr) }
                             throw IdeviceGatewayError.serviceError("Failed to mount personalized DDI")
                         }
                     }
                 }
             }
         }
     }

    public struct PairedDevice {
        public let name: String
        public let model: String
        public let udid: String
        public let pairingFilePath: String
        public let hostAltIrkHex: String
    }

    public func startWirelessPair(
        hostName: String,
        hostModel: String,
        outPath: String,
        onReady: @escaping (String, UInt16, [String: String]) -> Void,
        onPin: @escaping (String) -> Void
    ) throws -> PairedDevice {
        // 1. Generate pairing file to get the service ID
        var rpf: OpaquePointer? = nil
        let genErr = rp_pairing_file_generate(hostName, &rpf)
        if let genErr = genErr {
            defer { idevice_error_free(genErr) }
            throw IdeviceGatewayError.serviceError("Failed to generate pairing file")
        }
        defer { rp_pairing_file_free(rpf) }

        // 2. Serialize pairing file to bytes so we can parse it in Swift and extract the identifier
        var dataPtr: UnsafeMutablePointer<UInt8>? = nil
        var dataLen: UInt = 0
        let toBytesErr = rp_pairing_file_to_bytes(rpf, &dataPtr, &dataLen)
        if let toBytesErr = toBytesErr {
            defer { idevice_error_free(toBytesErr) }
            throw IdeviceGatewayError.serviceError("Failed to serialize pairing file to bytes")
        }

        var identifier = ""
        if let dataPtr = dataPtr {
            let plistData = Data(bytes: dataPtr, count: Int(dataLen))
            idevice_data_free(dataPtr, dataLen)
            if let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] {
                identifier = plist["identifier"] as? String ?? ""
            }
        }

        if identifier.isEmpty {
            throw IdeviceGatewayError.serviceError("Failed to parse identifier from pairing file")
        }

        // 3. Find a free port
        var actualPort: UInt16 = 0
        let socketFd = socket(AF_INET, SOCK_STREAM, 0)
        if socketFd >= 0 {
            var addr = sockaddr_in()
            addr.sin_len = __uint8_t(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0
            addr.sin_addr.s_addr = INADDR_ANY
            let bindRes = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(socketFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bindRes == 0 {
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let nameRes = withUnsafeMutablePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        getsockname(socketFd, $0, &len)
                    }
                }
                if nameRes == 0 {
                    actualPort = UInt16(bigEndian: addr.sin_port)
                }
            }
            close(socketFd)
        }

        if actualPort == 0 {
            actualPort = 5555 // fallback
        }

        // 4. Invoke onReady callback
        let txtRecords = [
            "txtvers": "1",
            "id": identifier,
            "model": hostModel,
            "name": hostName
        ]
        onReady(identifier, actualPort, txtRecords)

        // 5. Accept device pairing connection (blocking)
        var pairedRpf: OpaquePointer? = nil
        var hostAltIrk = [UInt8](repeating: 0, count: 16)

        // Wrap pin closure in convention(c) safe context block
        class PinContext {
            let callback: (String) -> Void
            init(_ callback: @escaping (String) -> Void) {
                self.callback = callback
            }
        }
        let pinContextObj = PinContext(onPin)
        let pinContextPtr = Unmanaged.passRetained(pinContextObj).toOpaque()
        defer { Unmanaged<PinContext>.fromOpaque(pinContextPtr).release() }

        let acceptErr = pairable_host_accept(
            hostName,
            hostModel,
            actualPort,
            { pin, context in
                guard let pin = pin, let context = context else { return }
                let ctxObj = Unmanaged<PinContext>.fromOpaque(context).takeUnretainedValue()
                ctxObj.callback(String(cString: pin))
            },
            pinContextPtr,
            &hostAltIrk,
            &pairedRpf
        )

        if let acceptErr = acceptErr {
            defer { idevice_error_free(acceptErr) }
            throw IdeviceGatewayError.serviceError("Pairing failed or cancelled")
        }

        guard let pairedRpf = pairedRpf else {
            throw IdeviceGatewayError.serviceError("No pairing file returned")
        }
        defer { rp_pairing_file_free(pairedRpf) }

        let writeErr = rp_pairing_file_write(pairedRpf, outPath)
        if let writeErr = writeErr {
            defer { idevice_error_free(writeErr) }
            throw IdeviceGatewayError.serviceError("Failed to write pairing file to path")
        }

        // Get alt_irk and identifier from paired file
        var pairedDataPtr: UnsafeMutablePointer<UInt8>? = nil
        var pairedDataLen: UInt = 0
        let serializeErr = rp_pairing_file_to_bytes(pairedRpf, &pairedDataPtr, &pairedDataLen)
        if let serializeErr = serializeErr {
            defer { idevice_error_free(serializeErr) }
            throw IdeviceGatewayError.serviceError("Failed to serialize paired file")
        }

        var altIrkHex = ""
        var pairedUdid = ""
        if let pairedDataPtr = pairedDataPtr {
            let plistData = Data(bytes: pairedDataPtr, count: Int(pairedDataLen))
            idevice_data_free(pairedDataPtr, pairedDataLen)
            if let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] {
                pairedUdid = plist["identifier"] as? String ?? ""
                if let altIrkData = plist["alt_irk"] as? Data {
                    altIrkHex = altIrkData.map { String(format: "%02x", $0) }.joined()
                }
            }
        }

        return PairedDevice(
            name: hostName,
            model: hostModel,
            udid: pairedUdid.isEmpty ? identifier : pairedUdid,
            pairingFilePath: outPath,
            hostAltIrkHex: altIrkHex
        )
    }
}
