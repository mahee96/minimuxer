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
import MachO
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

    #if canImport(Darwin)
    private static let rustLibHandle: UnsafeMutableRawPointer? = {
        let count = _dyld_image_count()
        for i in 0..<count {
            if let namePtr = _dyld_get_image_name(i) {
                let name = String(cString: namePtr)
                if name.contains("Minimuxer.framework") || name.contains("IDevice.framework") || name.hasSuffix("/Minimuxer") || name.hasSuffix("/IDevice") {
                    if let handle = dlopen(name, RTLD_LAZY) {
                        return handle
                    }
                }
            }
        }
        return nil
    }()

    private typealias PlistFreeType = @convention(c) (_ plist: plist_t?) -> Void
    private typealias PlistGetStringValType = @convention(c) (_ plist: plist_t?, _ val: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?) -> Void
    private typealias PlistDictGetItemType = @convention(c) (_ plist: plist_t?, _ key: UnsafePointer<Int8>?) -> plist_t?
    private typealias PlistGetUintValType = @convention(c) (_ plist: plist_t?, _ val: UnsafeMutablePointer<UInt64>?) -> Void

    private static let rust_plist_free: PlistFreeType? = {
        guard let handle = rustLibHandle else { return nil }
        if let sym = dlsym(handle, "plist_free") {
            return unsafeBitCast(sym, to: PlistFreeType.self)
        }
        return nil
    }()

    private static let rust_plist_get_string_val: PlistGetStringValType? = {
        guard let handle = rustLibHandle else { return nil }
        if let sym = dlsym(handle, "plist_get_string_val") {
            return unsafeBitCast(sym, to: PlistGetStringValType.self)
        }
        return nil
    }()

    private static let rust_plist_dict_get_item: PlistDictGetItemType? = {
        guard let handle = rustLibHandle else { return nil }
        if let sym = dlsym(handle, "plist_dict_get_item") {
            return unsafeBitCast(sym, to: PlistDictGetItemType.self)
        }
        return nil
    }()

    private static let rust_plist_get_uint_val: PlistGetUintValType? = {
        guard let handle = rustLibHandle else { return nil }
        if let sym = dlsym(handle, "plist_get_uint_val") {
            return unsafeBitCast(sym, to: PlistGetUintValType.self)
        }
        return nil
    }()
    #endif

    private func getRustPlistString(_ node: plist_t) -> String? {
        #if canImport(Darwin)
        if let getFn = Self.rust_plist_get_string_val {
            var valPtr: UnsafeMutablePointer<Int8>? = nil
            getFn(node, &valPtr)
            if let ptr = valPtr {
                let val = String(cString: ptr)
                free(ptr)
                return val
            }
        }
        return nil
        #else
        var valPtr: UnsafeMutablePointer<Int8>? = nil
        plist_get_string_val(node, &valPtr)
        if let ptr = valPtr {
            let val = String(cString: ptr)
            free(ptr)
            return val
        }
        return nil
        #endif
    }

    private func getRustPlistUint(_ node: plist_t) -> UInt64? {
        #if canImport(Darwin)
        if let getFn = Self.rust_plist_get_uint_val {
            var val: UInt64 = 0
            getFn(node, &val)
            return val
        }
        return nil
        #else
        var val: UInt64 = 0
        plist_get_uint_val(node, &val)
        return val
        #endif
    }

    private func getRustPlistDictItem(_ node: plist_t, key: String) -> plist_t? {
        #if canImport(Darwin)
        if let getFn = Self.rust_plist_dict_get_item {
            return getFn(node, key)
        }
        return nil
        #else
        return plist_dict_get_item(node, key)
        #endif
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
        // idevice_init_logger(enabled ? IdeviceLogLevel(rawValue: 4) : IdeviceLogLevel(rawValue: 0), IdeviceLogLevel(rawValue: 0), nil)
        idevice_init_logger(IdeviceLogLevel(rawValue: 0), IdeviceLogLevel(rawValue: 0), nil)
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

    private func performWithService<T>(
        connect: @escaping (OpaquePointer?, OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> UnsafeMutablePointer<IdeviceFfiError>?,
        cleanup: @escaping (OpaquePointer?) -> Void,
        serviceName: String,
        action: (OpaquePointer) throws -> T
    ) throws -> T {
        try ensureRPConnection()
        var client: OpaquePointer? = nil
        let err = connect(adapter, handshake, &client)
        if let err = err {
            defer { idevice_error_free(err) }
            throw IdeviceGatewayError.serviceError("Failed to connect to \(serviceName)")
        }
        guard let client = client else {
            throw IdeviceGatewayError.serviceError("Connected client for \(serviceName) was nil")
        }
        defer { cleanup(client) }
        return try action(client)
    }

    private func performWithUsbmuxdService<T>(
        connect: @escaping (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> UnsafeMutablePointer<IdeviceFfiError>?,
        cleanup: @escaping (OpaquePointer?) -> Void,
        serviceName: String,
        action: (OpaquePointer) throws -> T
    ) throws -> T {
        var addr: OpaquePointer? = nil
        var err = idevice_usbmuxd_default_addr_new(&addr)
        if let err = err {
            defer { idevice_error_free(err) }
            throw IdeviceGatewayError.connectionFailed("Failed to get usbmuxd default addr")
        }
        guard let addr = addr else {
            throw IdeviceGatewayError.connectionFailed("Usbmuxd default addr was nil")
        }
        
        var provider: OpaquePointer? = nil
        var provErr: UnsafeMutablePointer<IdeviceFfiError>? = nil
        
        var conn: OpaquePointer? = nil
        let connErr = idevice_usbmuxd_new_default_connection(0, &conn)
        if let connErr = connErr {
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
                defer { idevice_error_free(devErr) }
                idevice_usbmuxd_addr_free(addr)
                throw IdeviceGatewayError.connectionFailed("Failed to list usbmuxd devices")
            }
            if count > 0, let devicesPtr = devices, let firstDev = devicesPtr.pointee {
                defer { idevice_usbmuxd_device_list_free(devices, count) }
                let udidPtr = idevice_usbmuxd_device_get_udid(firstDev)
                let deviceID = idevice_usbmuxd_device_get_device_id(firstDev)
                provErr = usbmuxd_provider_new(addr, 0, udidPtr, deviceID, "minimuxer", &provider)
                if let udidPtr = udidPtr {
                    idevice_string_free(udidPtr)
                }
            } else {
                idevice_usbmuxd_addr_free(addr)
                throw IdeviceGatewayError.connectionFailed("No devices found on usbmuxd")
            }
        } else {
            idevice_usbmuxd_addr_free(addr)
            throw IdeviceGatewayError.connectionFailed("Usbmuxd connection was nil")
        }
        
        if let provErr = provErr {
            defer { idevice_error_free(provErr) }
            throw IdeviceGatewayError.connectionFailed("Failed to create usbmuxd provider")
        }
        guard let provider = provider else {
            throw IdeviceGatewayError.connectionFailed("Usbmuxd provider was nil")
        }
        defer { idevice_provider_free(provider) }

        var client: OpaquePointer? = nil
        let connectErr = connect(provider, &client)
        if let connectErr = connectErr {
            defer { idevice_error_free(connectErr) }
            throw IdeviceGatewayError.serviceError("Failed to connect to \(serviceName)")
        }
        guard let client = client else {
            throw IdeviceGatewayError.serviceError("Connected client for \(serviceName) was nil")
        }
        defer { cleanup(client) }
        return try action(client)
    }

    private func performWithEitherService<T>(
        connectRP: @escaping (OpaquePointer?, OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> UnsafeMutablePointer<IdeviceFfiError>?,
        connectUsbmuxd: @escaping (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> UnsafeMutablePointer<IdeviceFfiError>?,
        cleanup: @escaping (OpaquePointer?) -> Void,
        serviceName: String,
        action: (OpaquePointer) throws -> T
    ) throws -> T {
        if isRPPairing {
            return try performWithService(connect: connectRP, cleanup: cleanup, serviceName: serviceName, action: action)
        } else {
            return try performWithUsbmuxdService(connect: connectUsbmuxd, cleanup: cleanup, serviceName: serviceName, action: action)
        }
    }

    public func fetchUDID() -> String? {
        if isRPPairing {
            do {
                try ensureRPConnection()
            } catch {
                return nil
            }
            guard let adapter = adapter, let handshake = handshake else { return nil }
            var lockdownClient: OpaquePointer? = nil
            let connectErr = lockdownd_connect_rsd(adapter, handshake, &lockdownClient)
            if let connectErr = connectErr {
                idevice_error_free(connectErr)
                return nil
            }
            guard let client = lockdownClient else { return nil }
            defer { lockdownd_client_free(client) }

            var plistVal: plist_t? = nil
            let valErr = IDevice.lockdownd_get_value(client, "UniqueDeviceID", nil, &plistVal)
            if let valErr = valErr {
                idevice_error_free(valErr)
                return nil
            }
            if let plistVal = plistVal {
                defer {
                    #if canImport(Darwin)
                    Self.rust_plist_free?(plistVal)
                    #else
                    plist_free(plistVal)
                    #endif
                }
                return getRustPlistString(plistVal)
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

    public func getLockdownValue(key: String) throws -> String? {
        if isRPPairing && key == "ProductVersion" {
            return "17.0"
        }

        return try performWithEitherService(
            connectRP: lockdownd_connect_rsd,
            connectUsbmuxd: lockdownd_connect,
            cleanup: lockdownd_client_free,
            serviceName: "lockdownd"
        ) { client in
            var plistVal: plist_t? = nil
            #if canImport(Darwin)
            let valErr = IDevice.lockdownd_get_value(client, key, nil, &plistVal)
            #else
            let valErr = lockdownd_get_value(client, nil, key, &plistVal)
            #endif
            if let valErr = valErr {
                defer { idevice_error_free(valErr) }
                throw IdeviceGatewayError.serviceError("Failed to get lockdown value for key \(key)")
            }
            if let plistVal = plistVal {
                defer {
                    #if canImport(Darwin)
                    Self.rust_plist_free?(plistVal)
                    #else
                    plist_free(plistVal)
                    #endif
                }
                return getRustPlistString(plistVal)
            }
            return nil
        }
    }

    public func installProvisioningProfile(profile: Data) throws {
        try performWithEitherService(
            connectRP: misagent_connect_rsd,
            connectUsbmuxd: misagent_connect,
            cleanup: misagent_client_free,
            serviceName: "misagent"
        ) { client in
            try profile.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                if let baseAddress = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                    let installErr = misagent_install(client, baseAddress, profile.count)
                    if let installErr = installErr {
                        defer { idevice_error_free(installErr) }
                        throw IdeviceGatewayError.serviceError("Failed to install profile")
                    }
                }
            }
        }
    }

    public func removeProvisioningProfile(id: String) throws {
        try performWithEitherService(
            connectRP: misagent_connect_rsd,
            connectUsbmuxd: misagent_connect,
            cleanup: misagent_client_free,
            serviceName: "misagent"
        ) { client in
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
        try performWithEitherService(
            connectRP: installation_proxy_connect_rsd,
            connectUsbmuxd: installation_proxy_connect,
            cleanup: installation_proxy_client_free,
            serviceName: "instproxy"
        ) { client in
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
        try performWithEitherService(
            connectRP: afc_client_connect_rsd,
            connectUsbmuxd: afc_client_connect,
            cleanup: afc_client_free,
            serviceName: "AFC client"
        ) { client in
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
        try performWithEitherService(
            connectRP: installation_proxy_connect_rsd,
            connectUsbmuxd: installation_proxy_connect,
            cleanup: installation_proxy_client_free,
            serviceName: "instproxy"
        ) { client in
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

    private func getAppPaths(appId: String) throws -> (container: String, bundlePath: String) {
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
                let err = installation_proxy_get_apps(client, nil, &bundleIds, 1, &outResult, &outLen)
                if let err = err {
                    defer { idevice_error_free(err) }
                    throw IdeviceGatewayError.serviceError("Failed to lookup app paths")
                }
            }
            
            guard let resultPtr = outResult, outLen > 0 else {
                throw IdeviceGatewayError.serviceError("App not found: \(appId)")
            }
            
            let plistArray = resultPtr.assumingMemoryBound(to: plist_t?.self)
            var container = ""
            var bundlePath = ""
            
            for i in 0..<outLen {
                if let plistVal = plistArray[i] {
                    // Container
                    #if canImport(Darwin)
                    let containerPlist = getRustPlistDictItem(plistVal, key: "Container")
                    if let containerPlist = containerPlist {
                        if let ptr = getRustPlistString(containerPlist) {
                            container = ptr
                        }
                    }
                    
                    // Path
                    let pathPlist = getRustPlistDictItem(plistVal, key: "Path")
                    if let pathPlist = pathPlist {
                        if let ptr = getRustPlistString(pathPlist) {
                            bundlePath = ptr
                        }
                    }
                    #else
                    let containerPlist = plist_dict_get_item(plistVal, "Container")
                    if let containerPlist = containerPlist {
                        var valPtr: UnsafeMutablePointer<Int8>? = nil
                        plist_get_string_val(containerPlist, &valPtr)
                        if let ptr = valPtr {
                            container = String(cString: ptr)
                            free(ptr)
                        }
                    }
                    
                    // Path
                    let pathPlist = plist_dict_get_item(plistVal, "Path")
                    if let pathPlist = pathPlist {
                        var valPtr: UnsafeMutablePointer<Int8>? = nil
                        plist_get_string_val(pathPlist, &valPtr)
                        if let ptr = valPtr {
                            bundlePath = String(cString: ptr)
                            free(ptr)
                        }
                    }
                    #endif
                }
            }
            free(outResult)
            
            if container.isEmpty || bundlePath.isEmpty {
                throw IdeviceGatewayError.serviceError("Failed to resolve app paths")
            }
            return (container, bundlePath)
        }
    }
    
    private func sendDebugProxyCommand(client: OpaquePointer, name: String, args: [String]) throws {
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
            } else {
                throw IdeviceGatewayError.serviceError("Failed to construct debug proxy command: \(name)")
            }
        }
    }
    
    private func launchAppPre17(appId: String) throws {
        let (container, bundlePath) = try getAppPaths(appId: appId)
        
        try performWithEitherService(
            connectRP: lockdownd_connect_rsd,
            connectUsbmuxd: lockdownd_connect,
            cleanup: lockdownd_client_free,
            serviceName: "lockdownd"
        ) { lockdownClient in
            var port: UInt16 = 0
            var ssl: Bool = false
            
            let err = "com.apple.debugserver".withCString { serviceNamePtr in
                #if canImport(Darwin)
                return IDevice.lockdownd_start_service(lockdownClient, serviceNamePtr, &port, &ssl)
                #else
                return lockdownd_start_service(lockdownClient, serviceNamePtr, &port, &ssl)
                #endif
            }
            if let err = err {
                defer { idevice_error_free(err) }
                throw IdeviceGatewayError.serviceError("Failed to start debugserver service")
            }
            
            var addr: OpaquePointer? = nil
            var addrErr = idevice_usbmuxd_default_addr_new(&addr)
            if let addrErr = addrErr {
                defer { idevice_error_free(addrErr) }
                throw IdeviceGatewayError.connectionFailed("Failed to get usbmuxd default addr")
            }
            guard let addr = addr else {
                throw IdeviceGatewayError.connectionFailed("Usbmuxd default addr was nil")
            }
            defer { idevice_usbmuxd_addr_free(addr) }
            
            var conn: OpaquePointer? = nil
            let connErr = idevice_usbmuxd_new_default_connection(0, &conn)
            if let connErr = connErr {
                defer { idevice_error_free(connErr) }
                throw IdeviceGatewayError.connectionFailed("Failed to create usbmuxd connection")
            }
            guard let conn = conn else {
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
                defer { idevice_error_free(devErr) }
                throw IdeviceGatewayError.connectionFailed("Failed to list usbmuxd devices")
            }
            
            guard count > 0, let devicesPtr = devices, let firstDev = devicesPtr.pointee else {
                throw IdeviceGatewayError.connectionFailed("No devices found on usbmuxd")
            }
            defer { idevice_usbmuxd_device_list_free(devices, count) }
            
            let deviceID = idevice_usbmuxd_device_get_device_id(firstDev)
            
            var debugDevice: OpaquePointer? = nil
            let connectErr = "minimuxer-debug".withCString { labelPtr in
                return idevice_usbmuxd_connect_to_device(conn, deviceID, port, labelPtr, &debugDevice)
            }
            if let connectErr = connectErr {
                defer { idevice_error_free(connectErr) }
                throw IdeviceGatewayError.connectionFailed("Failed to connect to debugserver port \(port)")
            }
            connNeedsFree = false
            
            guard let debugDevice = debugDevice else {
                throw IdeviceGatewayError.connectionFailed("Debug device handle was nil")
            }
            var debugDeviceNeedsFree = true
            defer {
                if debugDeviceNeedsFree {
                    idevice_free(debugDevice)
                }
            }
            
            var stream: OpaquePointer? = nil
            let streamErr = idevice_to_stream(debugDevice, &stream)
            if let streamErr = streamErr {
                defer { idevice_error_free(streamErr) }
                throw IdeviceGatewayError.serviceError("Failed to convert device connection to stream")
            }
            debugDeviceNeedsFree = false
            
            guard let stream = stream else {
                throw IdeviceGatewayError.serviceError("Stream was nil")
            }
            var streamNeedsFree = true
            defer {
                if streamNeedsFree {
                    idevice_stream_free(stream)
                }
            }
            
            var debugProxyClient: OpaquePointer? = nil
            let proxyErr = debug_proxy_new(stream, &debugProxyClient)
            if let proxyErr = proxyErr {
                defer { idevice_error_free(proxyErr) }
                throw IdeviceGatewayError.serviceError("Failed to create debug proxy client")
            }
            streamNeedsFree = false
            
            guard let debugProxyClient = debugProxyClient else {
                throw IdeviceGatewayError.serviceError("Debug proxy client was nil")
            }
            defer { debug_proxy_free(debugProxyClient) }
            
            try self.sendDebugProxyCommand(client: debugProxyClient, name: "QSetMaxPacketSize", args: ["\(MinimuxerConstants.maxPacketSize)"])
            try self.sendDebugProxyCommand(client: debugProxyClient, name: "QSetWorkingDir", args: [container])
            
            try bundlePath.withCString { bundlePathPtr in
                var argvptrs: [UnsafePointer<Int8>?] = [bundlePathPtr, bundlePathPtr]
                var response: UnsafeMutablePointer<Int8>? = nil
                let argvErr = debug_proxy_set_argv(debugProxyClient, &argvptrs, UInt(argvptrs.count), &response)
                if let argvErr = argvErr {
                    defer { idevice_error_free(argvErr) }
                    throw IdeviceGatewayError.serviceError("Failed to set debug proxy argv")
                }
                if let response = response {
                    free(response)
                }
            }
            
            try self.sendDebugProxyCommand(client: debugProxyClient, name: "qLaunchSuccess", args: [])
            try self.sendDebugProxyCommand(client: debugProxyClient, name: "D", args: [])
        }
    }

    private func getDummyFfiError() -> UnsafeMutablePointer<IdeviceFfiError>? {
        var client: OpaquePointer? = nil
        #if canImport(Darwin)
        return IDevice.lockdownd_connect(nil, &client)
        #else
        return lockdownd_connect(nil, &client)
        #endif
    }

    public func debugApp(appId: String) throws {
        guard let versionStr = try getLockdownValue(key: "ProductVersion"),
              let majorStr = versionStr.split(separator: ".").first,
              let major = Int(majorStr) else {
            throw IdeviceGatewayError.serviceError("Failed to get product version for JIT")
        }
        
        if major < 17 {
            try launchAppPre17(appId: appId)
        } else {
            try performWithEitherService(
                connectRP: debug_proxy_connect_rsd,
                connectUsbmuxd: { [weak self] _, _ in
                    return self?.getDummyFfiError()
                },
                cleanup: debug_proxy_free,
                serviceName: "debug proxy"
            ) { client in
                // connection validation
            }
        }
    }

    public func debugProcess(pid: UInt32) throws {
        try performWithEitherService(
            connectRP: debug_proxy_connect_rsd,
            connectUsbmuxd: { [weak self] _, _ in
                return self?.getDummyFfiError()
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
        try performWithEitherService(
            connectRP: misagent_connect_rsd,
            connectUsbmuxd: misagent_connect,
            cleanup: misagent_client_free,
            serviceName: "misagent"
        ) { client in
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
    }

    public func performHeartbeat(interval: UInt64, newInterval: UnsafeMutablePointer<UInt64>) throws {
        try performWithEitherService(
            connectRP: heartbeat_connect_rsd,
            connectUsbmuxd: heartbeat_connect,
            cleanup: heartbeat_client_free,
            serviceName: "heartbeat"
        ) { client in
            let getErr = heartbeat_get_marco(client, interval, newInterval)
            if let getErr = getErr {
                defer { idevice_error_free(getErr) }
                throw IdeviceGatewayError.serviceError("Heartbeat receive failed")
            }
            let sendErr = heartbeat_send_polo(client)
            if let sendErr = sendErr {
                defer { idevice_error_free(sendErr) }
                throw IdeviceGatewayError.serviceError("Heartbeat send failed")
            }
        }
    }

    public func mountPersonalizedDdi(image: Data, trustcache: Data, manifest: Data) throws {
        guard isRPPairing else {
            throw IdeviceGatewayError.serviceError("Personalized DDI mounting is only supported over Remote Pairing (iOS 17+).")
        }
        var chipID: UInt64 = 0
        try performWithService(connect: lockdownd_connect_rsd, cleanup: { client in
            lockdownd_client_free(client)
        }, serviceName: "lockdownd") { lockdownClient in
            var plistVal: plist_t? = nil
            #if canImport(Darwin)
            let valErr = IDevice.lockdownd_get_value(lockdownClient, "UniqueChipID", nil, &plistVal)
            #else
            let valErr = lockdownd_get_value(lockdownClient, nil, "UniqueChipID", &plistVal)
            #endif
            if let valErr = valErr {
                defer { idevice_error_free(valErr) }
                throw IdeviceGatewayError.serviceError("Failed to get UniqueChipID")
            }
            if let plistVal = plistVal {
                defer {
                    #if canImport(Darwin)
                    Self.rust_plist_free?(plistVal)
                    #else
                    plist_free(plistVal)
                    #endif
                }
                if let val = getRustPlistUint(plistVal) {
                    chipID = val
                }
            }
        }

        try performWithService(connect: image_mounter_connect_rsd, cleanup: image_mounter_free, serviceName: "image mounter") { mounterClient in
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

    public func mountDeveloperImage(image: Data, signature: Data) throws {
        try performWithEitherService(
            connectRP: image_mounter_connect_rsd,
            connectUsbmuxd: image_mounter_connect,
            cleanup: image_mounter_free,
            serviceName: "image mounter"
        ) { client in
            // 1. Upload
            try image.withUnsafeBytes { imgBuf in
                try signature.withUnsafeBytes { sigBuf in
                    let uploadErr = image_mounter_upload_image(
                        client,
                        "Developer",
                        imgBuf.bindMemory(to: UInt8.self).baseAddress,
                        image.count,
                        sigBuf.bindMemory(to: UInt8.self).baseAddress,
                        signature.count
                    )
                    if let uploadErr = uploadErr {
                        defer { idevice_error_free(uploadErr) }
                        throw IdeviceGatewayError.serviceError("Failed to upload developer image")
                    }
                }
            }

            // 2. Mount
            try signature.withUnsafeBytes { sigBuf in
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
                    defer { idevice_error_free(mountErr) }
                    throw IdeviceGatewayError.serviceError("Failed to mount developer image")
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
