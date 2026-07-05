//
//  IdeviceGateway.swift
//  SideStore
//
//  Created by Magesh K on 05/07/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import IDevice

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

    private func getRustPlistString(_ node: plist_t) -> String? {
        var valPtr: UnsafeMutablePointer<Int8>? = nil
        plist_get_string_val(node, &valPtr)
        if let ptr = valPtr {
            let val = String(cString: ptr)
            free(ptr)
            return val
        }
        return nil
    }


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
        debugLog("[IdeviceGateway] cleanup() called")
        if let handshake = handshake {
            verboseLog("[IdeviceGateway] cleanup() freeing handshake")
            rsd_handshake_free(handshake)
            self.handshake = nil
        }
        if let adapter = adapter {
            verboseLog("[IdeviceGateway] cleanup() freeing adapter")
            adapter_free(adapter)
            self.adapter = nil
        }
        if let pairingFile = pairingFile {
            verboseLog("[IdeviceGateway] cleanup() freeing pairingFile")
            rp_pairing_file_free(pairingFile)
            self.pairingFile = nil
        }
    }

    public func setDeviceIP(_ ip: String) {
        debugLog("[IdeviceGateway] setDeviceIP(\(ip)) called")
        self.deviceIP = ip
        // Invalidate current cached connections
        if handshake != nil {
            debugLog("[IdeviceGateway] setDeviceIP invalidating handshake")
            rsd_handshake_free(handshake)
            self.handshake = nil
        }
        if adapter != nil {
            debugLog("[IdeviceGateway] setDeviceIP invalidating adapter")
            adapter_free(adapter)
            self.adapter = nil
        }
    }

    public func setLogging(_ enabled: Bool) {
        idevice_init_logger(enabled ? IdeviceLogLevel(rawValue: 4) : IdeviceLogLevel(rawValue: 0), IdeviceLogLevel(rawValue: 0), nil)
        // idevice_init_logger(IdeviceLogLevel(rawValue: 0), IdeviceLogLevel(rawValue: 0), nil)
    }

    public func start(pairingFileContent: String) throws {
        debugLog("[IdeviceGateway] start() called, pairingFileContent length: \(pairingFileContent.count)")
        cleanup()

        guard let data = pairingFileContent.data(using: .utf8) else {
            debugLog("[IdeviceGateway] start() failed to decode pairingFileContent data as UTF-8")
            throw IdeviceGatewayError.invalidPairingFile
        }

        // Check if pairing file is RPPairing
        if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            if plist["private_key"] != nil {
                verboseLog("[IdeviceGateway] start() detected private_key, isRPPairing = true")
                isRPPairing = true
            } else {
                verboseLog("[IdeviceGateway] start() plist did not contain private_key")
            }
        } else {
            debugLog("[IdeviceGateway] start() failed to parse plist from pairingFileContent")
        }

        if isRPPairing {
            try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                if let baseAddress = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                    verboseLog("[IdeviceGateway] start() calling rp_pairing_file_from_bytes")
                    let err = rp_pairing_file_from_bytes(baseAddress, UInt(data.count), &pairingFile)
                    if err != nil {
                        debugLog("[IdeviceGateway] start() rp_pairing_file_from_bytes failed")
                        throw IdeviceGatewayError.invalidPairingFile
                    }
                }
            }
            verboseLog("[IdeviceGateway] start() calling ensureRPConnection()")
            try ensureRPConnection()
        } else {
            // Traditional usbmuxd / lockdown connection path
            // For pre-iOS 17 devices, a default connection can be established without RPPairing tunnel
            verboseLog("[IdeviceGateway] start() setting isRPPairing = false (traditional pathway)")
            isRPPairing = false
        }
    }

    private func ensureRPConnection() throws {
        debugLog("[IdeviceGateway] ensureRPConnection() started, adapter: \(String(describing: adapter)), handshake: \(String(describing: handshake))")
        if adapter != nil && handshake != nil {
            verboseLog("[IdeviceGateway] ensureRPConnection() using existing connection")
            return
        }

        guard let pairingFile = pairingFile else {
            debugLog("[IdeviceGateway] ensureRPConnection() failed because pairingFile is nil")
            throw IdeviceGatewayError.invalidPairingFile
        }

        // Standard RPPairing socket address
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(49152).bigEndian
        addr.sin_addr.s_addr = inet_addr(deviceIP)

        let hostname = "minimuxer"
        var err: UnsafeMutablePointer<IdeviceFfiError>? = nil

        verboseLog("[IdeviceGateway] ensureRPConnection() calling tunnel_create_rppairing with deviceIP: \(deviceIP)")
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
            debugLog("[IdeviceGateway] ensureRPConnection() tunnel_create_rppairing failed")
            throw IdeviceGatewayError.connectionFailed("Tunnel creation failed")
        }
        debugLog("[IdeviceGateway] ensureRPConnection() tunnel_create_rppairing succeeded, adapter: \(String(describing: adapter)), handshake: \(String(describing: handshake))")
    }

    private func performWithService<T>(
        connect: @escaping (OpaquePointer?, OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> UnsafeMutablePointer<IdeviceFfiError>?,
        cleanup: @escaping (OpaquePointer?) -> Void,
        serviceName: String,
        action: (OpaquePointer) throws -> T
    ) throws -> T {
        debugLog("[IdeviceGateway] performWithService(\(serviceName)) started")
        try ensureRPConnection()
        var client: OpaquePointer? = nil
        let err = connect(adapter, handshake, &client)
        if let err = err {
            debugLog("[IdeviceGateway] performWithService(\(serviceName)) connect failed")
            defer { idevice_error_free(err) }
            throw IdeviceGatewayError.serviceError("Failed to connect to \(serviceName)")
        }
        guard let client = client else {
            debugLog("[IdeviceGateway] performWithService(\(serviceName)) client is nil")
            throw IdeviceGatewayError.serviceError("Connected client for \(serviceName) was nil")
        }
        defer {
            verboseLog("[IdeviceGateway] performWithService(\(serviceName)) performing cleanup")
            cleanup(client)
        }
        verboseLog("[IdeviceGateway] performWithService(\(serviceName)) executing action")
        return try action(client)
    }

    private func performWithUsbmuxdService<T>(
        connect: @escaping (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> UnsafeMutablePointer<IdeviceFfiError>?,
        cleanup: @escaping (OpaquePointer?) -> Void,
        serviceName: String,
        action: (OpaquePointer) throws -> T
    ) throws -> T {
        debugLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) started")
        var addr: OpaquePointer? = nil
        var err = idevice_usbmuxd_default_addr_new(&addr)
        if let err = err {
            debugLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) failed to get default addr")
            defer { idevice_error_free(err) }
            throw IdeviceGatewayError.connectionFailed("Failed to get usbmuxd default addr")
        }
        guard let addr = addr else {
            debugLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) usbmuxd default addr is nil")
            throw IdeviceGatewayError.connectionFailed("Usbmuxd default addr was nil")
        }
        
        var provider: OpaquePointer? = nil
        var provErr: UnsafeMutablePointer<IdeviceFfiError>? = nil
        
        var conn: OpaquePointer? = nil
        let connErr = idevice_usbmuxd_new_default_connection(0, &conn)
        if let connErr = connErr {
            debugLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) usbmuxd connection failed")
            defer { idevice_error_free(connErr) }
            idevice_usbmuxd_addr_free(addr)
            throw IdeviceGatewayError.connectionFailed("Failed to connect to usbmuxd")
        }
        
        if let conn = conn {
            defer { idevice_usbmuxd_connection_free(conn) }
            var devices: UnsafeMutablePointer<OpaquePointer?>? = nil
            var count: Int32 = 0
            let devErr = idevice_usbmuxd_get_devices(conn, &devices, &count)
            if let devErr = devErr {
                debugLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) failed to get devices")
                defer { idevice_error_free(devErr) }
                idevice_usbmuxd_addr_free(addr)
                throw IdeviceGatewayError.connectionFailed("Failed to list usbmuxd devices")
            }
            verboseLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) found \(count) devices")
            if count > 0, let devicesPtr = devices, let firstDev = devicesPtr.pointee {
                defer { idevice_usbmuxd_device_list_free(devices, count) }
                let udidPtr = idevice_usbmuxd_device_get_udid(firstDev)
                let deviceID = idevice_usbmuxd_device_get_device_id(firstDev)
                verboseLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) creating provider for deviceID: \(deviceID)")
                provErr = usbmuxd_provider_new(addr, 0, udidPtr, deviceID, "minimuxer", &provider)
                if let udidPtr = udidPtr {
                    idevice_string_free(udidPtr)
                }
            } else {
                verboseLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) no devices found on usbmuxd")
                idevice_usbmuxd_addr_free(addr)
                throw IdeviceGatewayError.connectionFailed("No devices found on usbmuxd")
            }
        } else {
            debugLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) usbmuxd connection was nil")
            idevice_usbmuxd_addr_free(addr)
            throw IdeviceGatewayError.connectionFailed("Usbmuxd connection was nil")
        }
        
        if let provErr = provErr {
            debugLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) provider creation failed")
            defer { idevice_error_free(provErr) }
            throw IdeviceGatewayError.connectionFailed("Failed to create usbmuxd provider")
        }
        guard let provider = provider else {
            debugLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) provider is nil")
            throw IdeviceGatewayError.connectionFailed("Usbmuxd provider was nil")
        }
        defer { idevice_provider_free(provider) }

        var client: OpaquePointer? = nil
        let connectErr = connect(provider, &client)
        if let connectErr = connectErr {
            debugLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) connect failed")
            defer { idevice_error_free(connectErr) }
            throw IdeviceGatewayError.serviceError("Failed to connect to \(serviceName)")
        }
        guard let client = client else {
            debugLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) client is nil")
            throw IdeviceGatewayError.serviceError("Connected client for \(serviceName) was nil")
        }
        defer {
            verboseLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) performing cleanup")
            cleanup(client)
        }
        verboseLog("[IdeviceGateway] performWithUsbmuxdService(\(serviceName)) executing action")
        return try action(client)
    }

    private func performWithEitherService<T>(
        connectRP: @escaping (OpaquePointer?, OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> UnsafeMutablePointer<IdeviceFfiError>?,
        connectUsbmuxd: @escaping (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> UnsafeMutablePointer<IdeviceFfiError>?,
        cleanup: @escaping (OpaquePointer?) -> Void,
        serviceName: String,
        action: (OpaquePointer) throws -> T
    ) throws -> T {
        debugLog("[IdeviceGateway] performWithEitherService(\(serviceName)) started, isRPPairing: \(isRPPairing)")
        if isRPPairing {
            return try performWithService(connect: connectRP, cleanup: cleanup, serviceName: serviceName, action: action)
        } else {
            return try performWithUsbmuxdService(connect: connectUsbmuxd, cleanup: cleanup, serviceName: serviceName, action: action)
        }
    }

    public func fetchUDID() -> String? {
        debugLog("[IdeviceGateway] fetchUDID() started, isRPPairing: \(isRPPairing)")
        if isRPPairing {
            do {
                verboseLog("[IdeviceGateway] fetchUDID() calling ensureRPConnection()")
                try ensureRPConnection()
            } catch {
                debugLog("[IdeviceGateway] fetchUDID() ensureRPConnection failed with error: \(error)")
                return nil
            }
            guard let adapter = adapter, let handshake = handshake else {
                debugLog("[IdeviceGateway] fetchUDID() adapter (\(String(describing: adapter))) or handshake (\(String(describing: handshake))) is nil")
                return nil
            }
            var lockdownClient: OpaquePointer? = nil
            verboseLog("[IdeviceGateway] fetchUDID() connecting lockdownd_connect_rsd")
            let connectErr = lockdownd_connect_rsd(adapter, handshake, &lockdownClient)
            if let connectErr = connectErr {
                debugLog("[IdeviceGateway] fetchUDID() lockdownd_connect_rsd failed")
                idevice_error_free(connectErr)
                return nil
            }
            guard let client = lockdownClient else {
                debugLog("[IdeviceGateway] fetchUDID() lockdownClient is nil after connect")
                return nil
            }
            defer { lockdownd_client_free(client) }

            var plistVal: plist_t? = nil
            verboseLog("[IdeviceGateway] fetchUDID() calling lockdownd_get_value for UniqueDeviceID")
            let valErr = lockdownd_get_value(client, "UniqueDeviceID", nil, &plistVal)
            if let valErr = valErr {
                debugLog("[IdeviceGateway] fetchUDID() lockdownd_get_value failed")
                idevice_error_free(valErr)
                return nil
            }
            if let plistVal = plistVal {
                defer {
                    plist_free(plistVal)
                }
                let udid = getRustPlistString(plistVal)
                verboseLog("[IdeviceGateway] fetchUDID() getRustPlistString returned UDID: \(String(describing: udid))")
                return udid
            }
            debugLog("[IdeviceGateway] fetchUDID() plistVal is nil")
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

    public func getLockdownValue(key: String) throws -> String? {
        debugLog("[IdeviceGateway] getLockdownValue(key: \(key)) started, isRPPairing: \(isRPPairing)")
        if isRPPairing && key == "ProductVersion" {
            verboseLog("[IdeviceGateway] getLockdownValue returning mock 17.0 for ProductVersion")
            return "17.0"
        }

        return try performWithEitherService(
            connectRP: lockdownd_connect_rsd,
            connectUsbmuxd: lockdownd_connect,
            cleanup: lockdownd_client_free,
            serviceName: "lockdownd"
        ) { client in
            var plistVal: plist_t? = nil
            verboseLog("[IdeviceGateway] getLockdownValue calling lockdownd_get_value for \(key)")
            let valErr = lockdownd_get_value(client, key, nil, &plistVal)
            if let valErr = valErr {
                debugLog("[IdeviceGateway] getLockdownValue lockdownd_get_value failed for \(key)")
                defer { idevice_error_free(valErr) }
                throw IdeviceGatewayError.serviceError("Failed to get lockdown value for key \(key)")
            }
            if let plistVal = plistVal {
                defer {
                    plist_free(plistVal)
                }
                let val = getRustPlistString(plistVal)
                verboseLog("[IdeviceGateway] getLockdownValue getRustPlistString returned: \(String(describing: val))")
                return val
            }
            debugLog("[IdeviceGateway] getLockdownValue plistVal is nil for \(key)")
            return nil
        }
    }

    public func installProvisioningProfile(profile: Data) throws {
        debugLog("[IdeviceGateway] installProvisioningProfile() called, profile length: \(profile.count)")
        try performWithEitherService(
            connectRP: misagent_connect_rsd,
            connectUsbmuxd: misagent_connect,
            cleanup: misagent_client_free,
            serviceName: "misagent"
        ) { client in
            try profile.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                if let baseAddress = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                    verboseLog("[IdeviceGateway] installProvisioningProfile() calling misagent_install")
                    let installErr = misagent_install(client, baseAddress, profile.count)
                    if let installErr = installErr {
                        debugLog("[IdeviceGateway] installProvisioningProfile() misagent_install failed")
                        defer { idevice_error_free(installErr) }
                        throw IdeviceGatewayError.serviceError("Failed to install profile")
                    }
                    debugLog("[IdeviceGateway] installProvisioningProfile() misagent_install succeeded")
                }
            }
        }
    }

    public func removeProvisioningProfile(id: String) throws {
        debugLog("[IdeviceGateway] removeProvisioningProfile() called, id: \(id)")
        try performWithEitherService(
            connectRP: misagent_connect_rsd,
            connectUsbmuxd: misagent_connect,
            cleanup: misagent_client_free,
            serviceName: "misagent"
        ) { client in
            try id.withCString { idPtr in
                verboseLog("[IdeviceGateway] removeProvisioningProfile() calling misagent_remove")
                let removeErr = misagent_remove(client, idPtr)
                if let removeErr = removeErr {
                    debugLog("[IdeviceGateway] removeProvisioningProfile() misagent_remove failed")
                    defer { idevice_error_free(removeErr) }
                    throw IdeviceGatewayError.serviceError("Failed to remove profile")
                }
                debugLog("[IdeviceGateway] removeProvisioningProfile() misagent_remove succeeded")
            }
        }
    }

    public func removeApp(bundleId: String) throws {
        debugLog("[IdeviceGateway] removeApp() called, bundleId: \(bundleId)")
        try performWithEitherService(
            connectRP: installation_proxy_connect_rsd,
            connectUsbmuxd: installation_proxy_connect,
            cleanup: installation_proxy_client_free,
            serviceName: "instproxy"
        ) { client in
            try bundleId.withCString { bundleIdPtr in
                verboseLog("[IdeviceGateway] removeApp() calling installation_proxy_uninstall")
                let uninstallErr = installation_proxy_uninstall(client, bundleIdPtr, nil)
                if let uninstallErr = uninstallErr {
                    debugLog("[IdeviceGateway] removeApp() installation_proxy_uninstall failed")
                    defer { idevice_error_free(uninstallErr) }
                    throw IdeviceGatewayError.serviceError("Failed to uninstall app")
                }
                debugLog("[IdeviceGateway] removeApp() installation_proxy_uninstall succeeded")
            }
        }
    }

    public func yeetAppAfc(bundleId: String, ipaBytes: Data) throws {
        debugLog("[IdeviceGateway] yeetAppAfc() called, bundleId: \(bundleId), ipaBytes size: \(ipaBytes.count)")
        try performWithEitherService(
            connectRP: afc_client_connect_rsd,
            connectUsbmuxd: afc_client_connect,
            cleanup: afc_client_free,
            serviceName: "AFC client"
        ) { client in
            // Ensure directory
            let stagingDir = "PublicStaging"
            verboseLog("[IdeviceGateway] yeetAppAfc() creating directory: \(stagingDir)")
            _ = stagingDir.withCString { dirPtr in
                afc_make_directory(client, dirPtr)
            }
            let bundleDir = "\(stagingDir)/\(bundleId)"
            verboseLog("[IdeviceGateway] yeetAppAfc() creating directory: \(bundleDir)")
            _ = bundleDir.withCString { dirPtr in
                afc_make_directory(client, dirPtr)
            }
 
            let path = "\(bundleDir)/app.ipa"
            var fileHandle: OpaquePointer? = nil
            verboseLog("[IdeviceGateway] yeetAppAfc() opening remote file: \(path)")
            let openErr = path.withCString { pathPtr in
                afc_file_open(client, pathPtr, AfcFopenMode(rawValue: 4), &fileHandle) // WrOnly/Wr mode
            }
            if let openErr = openErr {
                debugLog("[IdeviceGateway] yeetAppAfc() afc_file_open failed")
                defer { idevice_error_free(openErr) }
                throw IdeviceGatewayError.serviceError("Failed to open remote AFC file")
            }
            defer {
                verboseLog("[IdeviceGateway] yeetAppAfc() closing remote file handle")
                afc_file_close(fileHandle)
            }
 
            try ipaBytes.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                if let baseAddress = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                    verboseLog("[IdeviceGateway] yeetAppAfc() writing data to AFC file")
                    let writeErr = afc_file_write(fileHandle, baseAddress, ipaBytes.count)
                    if let writeErr = writeErr {
                        debugLog("[IdeviceGateway] yeetAppAfc() afc_file_write failed")
                        defer { idevice_error_free(writeErr) }
                        throw IdeviceGatewayError.serviceError("Failed to write to AFC file")
                    }
                    debugLog("[IdeviceGateway] yeetAppAfc() afc_file_write succeeded")
                }
            }
        }
    }

    public func installIpa(bundleId: String) throws {
        debugLog("[IdeviceGateway] installIpa() called, bundleId: \(bundleId)")
        try performWithEitherService(
            connectRP: installation_proxy_connect_rsd,
            connectUsbmuxd: installation_proxy_connect,
            cleanup: installation_proxy_client_free,
            serviceName: "instproxy"
        ) { client in
            let path = "PublicStaging/\(bundleId)/app.ipa"
            try path.withCString { pathPtr in
                verboseLog("[IdeviceGateway] installIpa() calling installation_proxy_install for path: \(path)")
                let installErr = installation_proxy_install(client, pathPtr, nil)
                if let installErr = installErr {
                    debugLog("[IdeviceGateway] installIpa() installation_proxy_install failed")
                    defer { idevice_error_free(installErr) }
                    throw IdeviceGatewayError.serviceError("Failed to install IPA")
                }
                debugLog("[IdeviceGateway] installIpa() installation_proxy_install succeeded")
            }
        }
    }

    private func getAppPaths(appId: String) throws -> (container: String, bundlePath: String) {
        debugLog("[IdeviceGateway] getAppPaths() called, appId: \(appId)")
        return try performWithEitherService(
            connectRP: installation_proxy_connect_rsd,
            connectUsbmuxd: installation_proxy_connect,
            cleanup: installation_proxy_client_free,
            serviceName: "instproxy"
        ) { client in
            var outResult: UnsafeMutableRawPointer? = nil
            var outLen: Int = 0
            
            try appId.withCString { appPtr in
                var bundleIds: [UnsafePointer<Int8>?] = [appPtr]
                verboseLog("[IdeviceGateway] getAppPaths() calling installation_proxy_get_apps")
                let err = installation_proxy_get_apps(client, nil, &bundleIds, 1, &outResult, &outLen)
                if let err = err {
                    debugLog("[IdeviceGateway] getAppPaths() installation_proxy_get_apps failed")
                    defer { idevice_error_free(err) }
                    throw IdeviceGatewayError.serviceError("Failed to lookup app paths")
                }
            }
            
            verboseLog("[IdeviceGateway] getAppPaths() installation_proxy_get_apps returned outLen: \(outLen)")
            guard let resultPtr = outResult, outLen > 0 else {
                verboseLog("[IdeviceGateway] getAppPaths() app not found")
                throw IdeviceGatewayError.serviceError("App not found: \(appId)")
            }
            
            let plistArray = resultPtr.assumingMemoryBound(to: plist_t?.self)
            var container = ""
            var bundlePath = ""
            
            for i in 0..<outLen {
                if let plistVal = plistArray[i] {
                    // Container
                    let containerPlist = plist_dict_get_item(plistVal, "Container")
                    if let containerPlist = containerPlist {
                        if let ptr = getRustPlistString(containerPlist) {
                            container = ptr
                            verboseLog("[IdeviceGateway] getAppPaths() found Container path: \(container)")
                        }
                    }
                    
                    // Path
                    let pathPlist = plist_dict_get_item(plistVal, "Path")
                    if let pathPlist = pathPlist {
                        if let ptr = getRustPlistString(pathPlist) {
                            bundlePath = ptr
                            verboseLog("[IdeviceGateway] getAppPaths() found Path: \(bundlePath)")
                        }
                    }
                }
            }
            free(outResult)
            
            if container.isEmpty || bundlePath.isEmpty {
                debugLog("[IdeviceGateway] getAppPaths() container or bundlePath is empty")
                throw IdeviceGatewayError.serviceError("Failed to resolve app paths")
            }
            return (container, bundlePath)
        }
    }
    
    private func sendDebugProxyCommand(client: OpaquePointer, name: String, args: [String]) throws {
        debugLog("[IdeviceGateway] sendDebugProxyCommand() called, name: \(name), args: \(args)")
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
                verboseLog("[IdeviceGateway] sendDebugProxyCommand() sending command \(name)")
                let sendErr = debug_proxy_send_command(client, cmdHandle, &response)
                if let sendErr = sendErr {
                    debugLog("[IdeviceGateway] sendDebugProxyCommand() failed for command \(name)")
                    defer { idevice_error_free(sendErr) }
                    throw IdeviceGatewayError.serviceError("Failed to send command to debug proxy: \(name)")
                }
                if let response = response {
                    let respStr = String(cString: response)
                    verboseLog("[IdeviceGateway] sendDebugProxyCommand() got response: \(respStr)")
                    free(response)
                } else {
                    debugLog("[IdeviceGateway] sendDebugProxyCommand() got empty response")
                }
            } else {
                debugLog("[IdeviceGateway] sendDebugProxyCommand() failed to construct command \(name)")
                throw IdeviceGatewayError.serviceError("Failed to construct debug proxy command: \(name)")
            }
        }
    }
    
    private func launchAppPre17(appId: String) throws {
        debugLog("[IdeviceGateway] launchAppPre17() called for appId: \(appId)")
        let (container, bundlePath) = try getAppPaths(appId: appId)
        
        try performWithEitherService(
            connectRP: lockdownd_connect_rsd,
            connectUsbmuxd: lockdownd_connect,
            cleanup: lockdownd_client_free,
            serviceName: "lockdownd"
        ) { lockdownClient in
            var port: UInt16 = 0
            var ssl: Bool = false
            
            verboseLog("[IdeviceGateway] launchAppPre17() starting debugserver service")
            let err = "com.apple.debugserver".withCString { serviceNamePtr in
                return lockdownd_start_service(lockdownClient, serviceNamePtr, &port, &ssl)
            }
            if let err = err {
                debugLog("[IdeviceGateway] launchAppPre17() failed to start debugserver")
                defer { idevice_error_free(err) }
                throw IdeviceGatewayError.serviceError("Failed to start debugserver service")
            }
            debugLog("[IdeviceGateway] launchAppPre17() debugserver started on port: \(port)")
            
            var addr: OpaquePointer? = nil
            var addrErr = idevice_usbmuxd_default_addr_new(&addr)
            if let addrErr = addrErr {
                debugLog("[IdeviceGateway] launchAppPre17() default_addr_new failed")
                defer { idevice_error_free(addrErr) }
                throw IdeviceGatewayError.connectionFailed("Failed to get usbmuxd default addr")
            }
            guard let addr = addr else {
                debugLog("[IdeviceGateway] launchAppPre17() usbmuxd default addr is nil")
                throw IdeviceGatewayError.connectionFailed("Usbmuxd default addr was nil")
            }
            defer { idevice_usbmuxd_addr_free(addr) }
            
            var conn: OpaquePointer? = nil
            verboseLog("[IdeviceGateway] launchAppPre17() creating default usbmuxd connection")
            let connErr = idevice_usbmuxd_new_default_connection(0, &conn)
            if let connErr = connErr {
                debugLog("[IdeviceGateway] launchAppPre17() new_default_connection failed")
                defer { idevice_error_free(connErr) }
                throw IdeviceGatewayError.connectionFailed("Failed to create usbmuxd connection")
            }
            guard let conn = conn else {
                debugLog("[IdeviceGateway] launchAppPre17() usbmuxd connection is nil")
                throw IdeviceGatewayError.connectionFailed("Usbmuxd connection was nil")
            }
            var connNeedsFree = true
            defer {
                if connNeedsFree {
                    idevice_usbmuxd_connection_free(conn)
                }
            }
            
            var devices: UnsafeMutablePointer<OpaquePointer?>? = nil
            var count: Int32 = 0
            let devErr = idevice_usbmuxd_get_devices(conn, &devices, &count)
            if let devErr = devErr {
                debugLog("[IdeviceGateway] launchAppPre17() get_devices failed")
                defer { idevice_error_free(devErr) }
                throw IdeviceGatewayError.connectionFailed("Failed to list usbmuxd devices")
            }
            
            guard count > 0, let devicesPtr = devices, let firstDev = devicesPtr.pointee else {
                verboseLog("[IdeviceGateway] launchAppPre17() no devices found on usbmuxd")
                throw IdeviceGatewayError.connectionFailed("No devices found on usbmuxd")
            }
            defer { idevice_usbmuxd_device_list_free(devices, count) }
            
            let deviceID = idevice_usbmuxd_device_get_device_id(firstDev)
            verboseLog("[IdeviceGateway] launchAppPre17() connecting to deviceID \(deviceID) debugserver port \(port)")
            
            var debugDevice: OpaquePointer? = nil
            let connectErr = "minimuxer-debug".withCString { labelPtr in
                return idevice_usbmuxd_connect_to_device(conn, deviceID, port, labelPtr, &debugDevice)
            }
            if let connectErr = connectErr {
                debugLog("[IdeviceGateway] launchAppPre17() connect_to_device failed")
                defer { idevice_error_free(connectErr) }
                throw IdeviceGatewayError.connectionFailed("Failed to connect to debugserver port \(port)")
            }
            connNeedsFree = false
            
            guard let debugDevice = debugDevice else {
                debugLog("[IdeviceGateway] launchAppPre17() debug device handle is nil")
                throw IdeviceGatewayError.connectionFailed("Debug device handle was nil")
            }
            var debugDeviceNeedsFree = true
            defer {
                if debugDeviceNeedsFree {
                    idevice_free(debugDevice)
                }
            }
            
            var stream: OpaquePointer? = nil
            verboseLog("[IdeviceGateway] launchAppPre17() converting debug device connection to stream")
            let streamErr = idevice_to_stream(debugDevice, &stream)
            if let streamErr = streamErr {
                debugLog("[IdeviceGateway] launchAppPre17() idevice_to_stream failed")
                defer { idevice_error_free(streamErr) }
                throw IdeviceGatewayError.serviceError("Failed to convert device connection to stream")
            }
            debugDeviceNeedsFree = false
            
            guard let stream = stream else {
                debugLog("[IdeviceGateway] launchAppPre17() stream is nil")
                throw IdeviceGatewayError.serviceError("Stream was nil")
            }
            var streamNeedsFree = true
            defer {
                if streamNeedsFree {
                    idevice_stream_free(stream)
                }
            }
            
            var debugProxyClient: OpaquePointer? = nil
            verboseLog("[IdeviceGateway] launchAppPre17() creating debug proxy client")
            let proxyErr = debug_proxy_new(stream, &debugProxyClient)
            if let proxyErr = proxyErr {
                debugLog("[IdeviceGateway] launchAppPre17() debug_proxy_new failed")
                defer { idevice_error_free(proxyErr) }
                throw IdeviceGatewayError.serviceError("Failed to create debug proxy client")
            }
            streamNeedsFree = false
            
            guard let debugProxyClient = debugProxyClient else {
                debugLog("[IdeviceGateway] launchAppPre17() debugProxyClient is nil")
                throw IdeviceGatewayError.serviceError("Debug proxy client was nil")
            }
            defer { debug_proxy_free(debugProxyClient) }
            
            verboseLog("[IdeviceGateway] launchAppPre17() configuring debug proxy workspace")
            try self.sendDebugProxyCommand(client: debugProxyClient, name: "QSetMaxPacketSize", args: ["\(MinimuxerConstants.maxPacketSize)"])
            try self.sendDebugProxyCommand(client: debugProxyClient, name: "QSetWorkingDir", args: [container])
            
            try bundlePath.withCString { bundlePathPtr in
                var argvptrs: [UnsafePointer<Int8>?] = [bundlePathPtr, bundlePathPtr]
                var response: UnsafeMutablePointer<Int8>? = nil
                verboseLog("[IdeviceGateway] launchAppPre17() setting argv for \(bundlePath)")
                let argvErr = debug_proxy_set_argv(debugProxyClient, &argvptrs, UInt(argvptrs.count), &response)
                if let argvErr = argvErr {
                    debugLog("[IdeviceGateway] launchAppPre17() debug_proxy_set_argv failed")
                    defer { idevice_error_free(argvErr) }
                    throw IdeviceGatewayError.serviceError("Failed to set debug proxy argv")
                }
                if let response = response {
                    let respStr = String(cString: response)
                    verboseLog("[IdeviceGateway] launchAppPre17() argv response: \(respStr)")
                    free(response)
                }
            }
            
            verboseLog("[IdeviceGateway] launchAppPre17() launching application")
            try self.sendDebugProxyCommand(client: debugProxyClient, name: "qLaunchSuccess", args: [])
            try self.sendDebugProxyCommand(client: debugProxyClient, name: "D", args: [])
            debugLog("[IdeviceGateway] launchAppPre17() app launched successfully")
        }
    }

    private func getDummyffiError() -> UnsafeMutablePointer<IdeviceFfiError>? {
        debugLog("[IdeviceGateway] getDummyffiError() called")
        var client: OpaquePointer? = nil
        let err = lockdownd_connect(nil, &client)
        debugLog("[IdeviceGateway] getDummyffiError() returned: \(String(describing: err))")
        return err
    }

    public func debugApp(appId: String) throws {
        debugLog("[IdeviceGateway] debugApp() called, appId: \(appId)")
        guard let versionStr = try getLockdownValue(key: "ProductVersion"),
              let majorStr = versionStr.split(separator: ".").first,
              let major = Int(majorStr) else {
            debugLog("[IdeviceGateway] debugApp() failed to get ProductVersion")
            throw IdeviceGatewayError.serviceError("Failed to get product version for JIT")
        }
        
        verboseLog("[IdeviceGateway] debugApp() ProductVersion major: \(major)")
        if major < 17 {
            try launchAppPre17(appId: appId)
        } else {
            try performWithEitherService(
                connectRP: debug_proxy_connect_rsd,
                connectUsbmuxd: { [weak self] _, _ in
                    debugLog("[IdeviceGateway] debugApp() usbmuxd placeholder called")
                    return self?.getDummyffiError()
                },
                cleanup: debug_proxy_free,
                serviceName: "debug proxy"
            ) { client in
                debugLog("[IdeviceGateway] debugApp() connection validation succeeded")
            }
        }
    }

    public func debugProcess(pid: UInt32) throws {
        debugLog("[IdeviceGateway] debugProcess() called, pid: \(pid)")
        try performWithEitherService(
            connectRP: debug_proxy_connect_rsd,
            connectUsbmuxd: { [weak self] _, _ in
                debugLog("[IdeviceGateway] debugProcess() usbmuxd placeholder called")
                return self?.getDummyffiError()
            },
            cleanup: debug_proxy_free,
            serviceName: "debug proxy"
        ) { client in
            let commands = [("vAttach", [String(format: "%02X", pid)]), ("D", [])]
            for (name, args) in commands {
                try sendDebugProxyCommand(client: client, name: name, args: args)
            }
        }
    }

    public func dumpProfiles(docsPath: String) throws -> String {
        debugLog("[IdeviceGateway] dumpProfiles() called, docsPath: \(docsPath)")
        return try performWithEitherService(
            connectRP: misagent_connect_rsd,
            connectUsbmuxd: misagent_connect,
            cleanup: misagent_client_free,
            serviceName: "misagent"
        ) { client in
            var outProfiles: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>? = nil
            var outProfilesLen: UnsafeMutablePointer<Int>? = nil
            var outCount: Int = 0

            verboseLog("[IdeviceGateway] dumpProfiles() calling misagent_copy_all")
            let copyErr = misagent_copy_all(client, &outProfiles, &outProfilesLen, &outCount)
            if let copyErr = copyErr {
                debugLog("[IdeviceGateway] dumpProfiles() misagent_copy_all failed")
                defer { idevice_error_free(copyErr) }
                throw IdeviceGatewayError.serviceError("Failed to copy profiles from misagent")
            }

            let path = docsPath.hasPrefix("file://") ? String(docsPath.dropFirst(7)) : docsPath
            let dumpDir = "\(path)/PROVISION"
            verboseLog("[IdeviceGateway] dumpProfiles() writing profiles to: \(dumpDir), count: \(outCount)")
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
            debugLog("[IdeviceGateway] dumpProfiles() complete")
            return dumpDir
        }
    }

    public func performHeartbeat(interval: UInt64, newInterval: UnsafeMutablePointer<UInt64>) throws {
        debugLog("[IdeviceGateway] performHeartbeat() called, interval: \(interval)")
        try performWithEitherService(
            connectRP: heartbeat_connect_rsd,
            connectUsbmuxd: heartbeat_connect,
            cleanup: heartbeat_client_free,
            serviceName: "heartbeat"
        ) { client in
            verboseLog("[IdeviceGateway] performHeartbeat() calling heartbeat_get_marco")
            let getErr = heartbeat_get_marco(client, interval, newInterval)
            if let getErr = getErr {
                debugLog("[IdeviceGateway] performHeartbeat() heartbeat_get_marco failed")
                defer { idevice_error_free(getErr) }
                throw IdeviceGatewayError.serviceError("Heartbeat receive failed")
            }
            verboseLog("[IdeviceGateway] performHeartbeat() calling heartbeat_send_polo")
            let sendErr = heartbeat_send_polo(client)
            if let sendErr = sendErr {
                debugLog("[IdeviceGateway] performHeartbeat() heartbeat_send_polo failed")
                defer { idevice_error_free(sendErr) }
                throw IdeviceGatewayError.serviceError("Heartbeat send failed")
            }
            debugLog("[IdeviceGateway] performHeartbeat() succeeded, newInterval: \(newInterval.pointee)")
        }
    }

    public func mountPersonalizedDdi(image: Data, trustcache: Data, manifest: Data) throws {
        debugLog("[IdeviceGateway] mountPersonalizedDdi() called, image size: \(image.count), trustcache size: \(trustcache.count), manifest size: \(manifest.count)")
        guard isRPPairing else {
            debugLog("[IdeviceGateway] mountPersonalizedDdi() failed: isRPPairing is false")
            throw IdeviceGatewayError.serviceError("Personalized DDI mounting is only supported over Remote Pairing (iOS 17+).")
        }
        var chipID: UInt64 = 0
        try performWithService(connect: lockdownd_connect_rsd, cleanup: { client in
            lockdownd_client_free(client)
        }, serviceName: "lockdownd") { lockdownClient in
            var plistVal: plist_t? = nil
            verboseLog("[IdeviceGateway] mountPersonalizedDdi() getting UniqueChipID")
            let valErr = lockdownd_get_value(lockdownClient, "UniqueChipID", nil, &plistVal)
            if let valErr = valErr {
                debugLog("[IdeviceGateway] mountPersonalizedDdi() lockdownd_get_value failed")
                defer { idevice_error_free(valErr) }
                throw IdeviceGatewayError.serviceError("Failed to get UniqueChipID")
            }
            if let plistVal = plistVal {
                defer {
                    plist_free(plistVal)
                }
                var val: UInt64 = 0
                plist_get_uint_val(plistVal, &val)
                chipID = val
                verboseLog("[IdeviceGateway] mountPersonalizedDdi() got chipID: \(chipID)")
            }
        }

        try performWithService(connect: image_mounter_connect_rsd, cleanup: image_mounter_free, serviceName: "image mounter") { mounterClient in
            try image.withUnsafeBytes { imgBuf in
                try trustcache.withUnsafeBytes { tcBuf in
                    try manifest.withUnsafeBytes { manBuf in
                        verboseLog("[IdeviceGateway] mountPersonalizedDdi() mounting image on Remote Pairing client")
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
                             debugLog("[IdeviceGateway] mountPersonalizedDdi() mount failed")
                             defer { idevice_error_free(mountErr) }
                             throw IdeviceGatewayError.serviceError("Failed to mount personalized DDI")
                         }
                         debugLog("[IdeviceGateway] mountPersonalizedDdi() mount succeeded")
                      }
                  }
              }
          }
      }

    public func mountDeveloperImage(image: Data, signature: Data) throws {
        debugLog("[IdeviceGateway] mountDeveloperImage() called, image size: \(image.count), signature size: \(signature.count)")
        try performWithEitherService(
            connectRP: image_mounter_connect_rsd,
            connectUsbmuxd: image_mounter_connect,
            cleanup: image_mounter_free,
            serviceName: "image mounter"
        ) { client in
            // 1. Upload
            try image.withUnsafeBytes { imgBuf in
                try signature.withUnsafeBytes { sigBuf in
                    verboseLog("[IdeviceGateway] mountDeveloperImage() uploading image")
                    let uploadErr = image_mounter_upload_image(
                        client,
                        "Developer",
                        imgBuf.bindMemory(to: UInt8.self).baseAddress,
                        image.count,
                        sigBuf.bindMemory(to: UInt8.self).baseAddress,
                        signature.count
                    )
                    if let uploadErr = uploadErr {
                        debugLog("[IdeviceGateway] mountDeveloperImage() upload failed")
                        defer { idevice_error_free(uploadErr) }
                        throw IdeviceGatewayError.serviceError("Failed to upload developer image")
                    }
                    debugLog("[IdeviceGateway] mountDeveloperImage() upload succeeded")
                }
            }

            // 2. Mount
            try signature.withUnsafeBytes { sigBuf in
                verboseLog("[IdeviceGateway] mountDeveloperImage() mounting image")
                let mountErr = image_mounter_mount_image(
                    client,
                    "Developer",
                    sigBuf.bindMemory(to: UInt8.self).baseAddress,
                    signature.count,
                    nil,
                    0,
                    nil
                )
                if let mountErr = mountErr {
                    debugLog("[IdeviceGateway] mountDeveloperImage() mount failed")
                    defer { idevice_error_free(mountErr) }
                    throw IdeviceGatewayError.serviceError("Failed to mount developer image")
                }
                debugLog("[IdeviceGateway] mountDeveloperImage() mount succeeded")
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
        debugLog("[IdeviceGateway] startWirelessPair() called, hostName: \(hostName), hostModel: \(hostModel), outPath: \(outPath)")
        // 1. Generate pairing file to get the service ID
        var rpf: OpaquePointer? = nil
        verboseLog("[IdeviceGateway] startWirelessPair() generating pairing file")
        let genErr = rp_pairing_file_generate(hostName, &rpf)
        if let genErr = genErr {
            debugLog("[IdeviceGateway] startWirelessPair() rp_pairing_file_generate failed")
            defer { idevice_error_free(genErr) }
            throw IdeviceGatewayError.serviceError("Failed to generate pairing file")
        }
        defer { rp_pairing_file_free(rpf) }

        // 2. Serialize pairing file to bytes so we can parse it in Swift and extract the identifier
        var dataPtr: UnsafeMutablePointer<UInt8>? = nil
        var dataLen: UInt = 0
        verboseLog("[IdeviceGateway] startWirelessPair() serializing pairing file to bytes")
        let toBytesErr = rp_pairing_file_to_bytes(rpf, &dataPtr, &dataLen)
        if let toBytesErr = toBytesErr {
            debugLog("[IdeviceGateway] startWirelessPair() rp_pairing_file_to_bytes failed")
            defer { idevice_error_free(toBytesErr) }
            throw IdeviceGatewayError.serviceError("Failed to serialize pairing file to bytes")
        }

        var identifier = ""
        if let dataPtr = dataPtr {
            let plistData = Data(bytes: dataPtr, count: Int(dataLen))
            idevice_data_free(dataPtr, dataLen)
            if let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] {
                identifier = plist["identifier"] as? String ?? ""
                verboseLog("[IdeviceGateway] startWirelessPair() parsed identifier: \(identifier)")
            }
        }

        if identifier.isEmpty {
            debugLog("[IdeviceGateway] startWirelessPair() failed: parsed identifier is empty")
            throw IdeviceGatewayError.serviceError("Failed to parse identifier from pairing file")
        }

        // 3. Find a free port
        var actualPort: UInt16 = 0
        verboseLog("[IdeviceGateway] startWirelessPair() finding free port")
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
                    verboseLog("[IdeviceGateway] startWirelessPair() bound to port: \(actualPort)")
                }
            }
            close(socketFd)
        }

        if actualPort == 0 {
            actualPort = 5555 // fallback
            verboseLog("[IdeviceGateway] startWirelessPair() fallback to port: \(actualPort)")
        }

        // 4. Invoke onReady callback
        let txtRecords = [
            "txtvers": "1",
            "id": identifier,
            "model": hostModel,
            "name": hostName
        ]
        verboseLog("[IdeviceGateway] startWirelessPair() invoking onReady")
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

        verboseLog("[IdeviceGateway] startWirelessPair() waiting for connection via pairable_host_accept...")
        let acceptErr = pairable_host_accept(
            hostName,
            hostModel,
            actualPort,
            { pin, context in
                guard let pin = pin, let context = context else { return }
                let ctxObj = Unmanaged<PinContext>.fromOpaque(context).takeUnretainedValue()
                let pinStr = String(cString: pin)
                verboseLog("[IdeviceGateway] startWirelessPair() received pin: \(pinStr)")
                ctxObj.callback(pinStr)
            },
            pinContextPtr,
            &hostAltIrk,
            &pairedRpf
        )

        if let acceptErr = acceptErr {
            debugLog("[IdeviceGateway] startWirelessPair() pairable_host_accept failed")
            defer { idevice_error_free(acceptErr) }
            throw IdeviceGatewayError.serviceError("Pairing failed or cancelled")
        }

        guard let pairedRpf = pairedRpf else {
            debugLog("[IdeviceGateway] startWirelessPair() pairedRpf is nil")
            throw IdeviceGatewayError.serviceError("No pairing file returned")
        }
        defer { rp_pairing_file_free(pairedRpf) }

        verboseLog("[IdeviceGateway] startWirelessPair() writing pairing file to: \(outPath)")
        let writeErr = rp_pairing_file_write(pairedRpf, outPath)
        if let writeErr = writeErr {
            debugLog("[IdeviceGateway] startWirelessPair() rp_pairing_file_write failed")
            defer { idevice_error_free(writeErr) }
            throw IdeviceGatewayError.serviceError("Failed to write pairing file to path")
        }

        // Get alt_irk and identifier from paired file
        var pairedDataPtr: UnsafeMutablePointer<UInt8>? = nil
        var pairedDataLen: UInt = 0
        verboseLog("[IdeviceGateway] startWirelessPair() serializing paired file to bytes")
        let serializeErr = rp_pairing_file_to_bytes(pairedRpf, &pairedDataPtr, &pairedDataLen)
        if let serializeErr = serializeErr {
            debugLog("[IdeviceGateway] startWirelessPair() rp_pairing_file_to_bytes failed")
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
                verboseLog("[IdeviceGateway] startWirelessPair() parsed pairedUdid: \(pairedUdid), altIrkHex length: \(altIrkHex.count)")
            }
        }

        debugLog("[IdeviceGateway] startWirelessPair() pairing complete")
        return PairedDevice(
            name: hostName,
            model: hostModel,
            udid: pairedUdid.isEmpty ? identifier : pairedUdid,
            pairingFilePath: outPath,
            hostAltIrkHex: altIrkHex
        )
    }
}
