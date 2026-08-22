//
//  LibimobiledeviceGateway.swift
//  Minimuxer
//
//  Created by Magesh K on 22/08/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import libimobiledevice
import DeviceGatewayAPI
internal import MinimuxerCommon

internal final class LibimobiledeviceGatewayError: DeviceGatewayError {
    override var errorDescription: String? {
        switch code {
        case .connectionFailed:
            return "Failed to connect to device via libimobiledevice: \(reason)"
        case .serviceError:
            return "libimobiledevice service operation failed: \(reason)"
        case .noConnection:
            return "No connection to the device via libimobiledevice."
        case .notInitialized:
            return "LibimobiledeviceGateway not initialized. start() should be called first."
        case .unsupportedOperation:
            return "Operation '\(reason)' is not supported by libimobiledevice gateway."
        default:
            return super.errorDescription
        }
    }
}



package final class LibimobiledeviceGateway: @unchecked Sendable, DeviceGatewayAPI {
    package static let shared = LibimobiledeviceGateway()

    public private(set) var isRPPairing: Bool = false
    public private(set) var pairingFileType: PairingProtocol = .unknown
    public private(set) var pairingFileData: Data? = nil {
        didSet {
            var pairingDict: [String: Any]? = nil
            if let pairingFileData {
                pairingDict = try? PropertyListSerialization.propertyList(
                    from: pairingFileData,
                    options: [],
                    format: nil
                ) as? [String: Any]
            }
            self.pairingDataDict = pairingDict
        }
    }
    public private(set) var pairingDataDict: [String: Any]? = nil

    private var cachedUDID: String? = nil
    private var isInitialized = false
    private var deviceEndpointIp: String? = nil

    package init() {}

    deinit {
        cleanup()
    }

    private func cleanup() {
        debugLog("[LibimobiledeviceGateway] cleanup() called")
        isInitialized = false
        self.pairingFileData = nil
        self.cachedUDID = nil
        self.isRPPairing = false
        self.pairingFileType = .unknown
    }

    public func getPairingFileType() -> PairingProtocol {
        return pairingFileType
    }

    public func setDeviceEndpointIp(_ ip: String?) {
        debugLog("[LibimobiledeviceGateway] setDeviceEndpointIp(\(ip ?? "nil")) called")
        self.deviceEndpointIp = ip
    }

    public func setLogging(_ enabled: Bool) {
        DeviceGatewayLogging.setLogging(enabled)
        debugLog("[LibimobiledeviceGateway] setLogging(\(enabled)) called")
        idevice_set_debug_level(enabled ? 1 : 0)
    }

    private func verifyInitialized() throws {
        guard isInitialized, cachedUDID != nil else {
            throw LibimobiledeviceGatewayError(.notInitialized)
        }
    }

    // Helper: Opens an idevice_t connection (looking up both USBMUX and Network)
    private func withDevice<T>(_ body: (idevice_t) throws -> T) throws -> T {
        try verifyInitialized()
        guard let udid = self.cachedUDID else {
            throw LibimobiledeviceGatewayError(.notInitialized)
        }
        var device: idevice_t? = nil
        let opts = idevice_options(rawValue: IDEVICE_LOOKUP_USBMUX.rawValue | IDEVICE_LOOKUP_NETWORK.rawValue)
        let err = idevice_new_with_options(&device, udid, opts)
        guard err == IDEVICE_E_SUCCESS, let device = device else {
            throw LibimobiledeviceGatewayError(.connectionFailed, reason: "idevice_new_with_options failed with code \(err.rawValue)")
        }
        defer { idevice_free(device) }
        return try body(device)
    }

    // Helper: Establishes a lockdown session with handshake
    private func withLockdown<T>(_ body: (idevice_t, lockdownd_client_t) throws -> T) throws -> T {
        try withDevice { device in
            var client: lockdownd_client_t? = nil
            let err = lockdownd_client_new_with_handshake(device, &client, "SideStore")
            guard err == LOCKDOWN_E_SUCCESS, let client = client else {
                throw LibimobiledeviceGatewayError(.connectionFailed, reason: "lockdownd_client_new_with_handshake failed with code \(err.rawValue)")
            }
            defer { lockdownd_client_free(client) }
            return try body(device, client)
        }
    }

    // Helper: Starts a lockdown service descriptor and creates a typed client
    private func withService<Client, E: RawRepresentable, T>(
        serviceIdentifier: String,
        create: (idevice_t?, lockdownd_service_descriptor_t?, UnsafeMutablePointer<Client?>?) -> E,
        cleanup: (Client?) -> E,
        _ body: (Client) throws -> T
    ) throws -> T where E.RawValue: BinaryInteger {
        try withLockdown { device, lockdown in
            var serviceDescriptor: lockdownd_service_descriptor_t? = nil
            let sErr = lockdownd_start_service(lockdown, serviceIdentifier, &serviceDescriptor)
            guard sErr == LOCKDOWN_E_SUCCESS, let serviceDescriptor = serviceDescriptor else {
                throw LibimobiledeviceGatewayError(.serviceError, reason: "Failed to start lockdown service '\(serviceIdentifier)': code \(sErr.rawValue)")
            }
            defer { lockdownd_service_descriptor_free(serviceDescriptor) }

            var client: Client? = nil
            let cErr = create(device, serviceDescriptor, &client)
            guard cErr.rawValue == 0, let client = client else {
                throw LibimobiledeviceGatewayError(.serviceError, reason: "Failed to create client for '\(serviceIdentifier)': code \(cErr.rawValue)")
            }
            defer { _ = cleanup(client) }
            return try body(client)
        }
    }

    func syncStart(pairingFileContent: String) throws {
        debugLog("[LibimobiledeviceGateway] start() called")
        cleanup()

        guard let data = pairingFileContent.data(using: .utf8) else {
            throw LibimobiledeviceGatewayError(.invalidPairingFile, reason: "UTF-8 encoding failed")
        }

        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw LibimobiledeviceGatewayError(.invalidPairingFile, reason: "Could not parse plist")
        }

        let requiredLockdownKeys = [
            "WiFiMACAddress", "SystemBUID", "RootPrivateKey", "HostPrivateKey",
            "HostID", "RootCertificate", "UDID", "EscrowBag", "HostCertificate",
            "DeviceCertificate"
        ]
        let missing = requiredLockdownKeys.filter { plist[$0] == nil }
        guard missing.isEmpty else {
            throw LibimobiledeviceGatewayError(.invalidPairingFile, reason: "Missing Lockdown attributes: \(missing.joined(separator: ", "))")
        }

        guard let udid = plist["UDID"] as? String, !udid.isEmpty else {
            throw LibimobiledeviceGatewayError(.invalidPairingFile, reason: "Missing UDID in pairing file")
        }

        self.pairingFileData = data
        self.pairingFileType = .lockdown
        self.isRPPairing = false
        self.cachedUDID = udid
        self.isInitialized = true

        debugLog("[LibimobiledeviceGateway] Initialized successfully with Lockdown pairing for UDID: \(udid)")
    }

    func syncFetchUDID() throws -> String? {
        try verifyInitialized()
        return cachedUDID
    }

    func syncGetLockdownValue(key: String) throws -> String? {
        try withLockdown { _, client in
            var valNode: plist_t? = nil
            let err = lockdownd_get_value(client, nil, key, &valNode)
            guard err == LOCKDOWN_E_SUCCESS, let valNode = valNode else {
                return nil
            }
            defer { plist_free(valNode) }

            var valPtr: UnsafeMutablePointer<CChar>? = nil
            plist_get_string_val(valNode, &valPtr)
            if let valPtr = valPtr {
                let val = String(cString: valPtr)
                free(valPtr)
                return val
            }
            return nil
        }
    }

    func syncIsDDIMounted() throws -> Bool {
        try withService(
            serviceIdentifier: "com.apple.mobile.mobile_image_mounter",
            create: mobile_image_mounter_new,
            cleanup: mobile_image_mounter_free
        ) { mounter in
            var resultPlist: plist_t? = nil
            let err = mobile_image_mounter_lookup_image(mounter, "Developer", &resultPlist)
            guard err == MOBILE_IMAGE_MOUNTER_E_SUCCESS, let resultPlist = resultPlist else {
                return false
            }
            defer { plist_free(resultPlist) }

            let sigDict = plist_dict_get_item(resultPlist, "ImageSignature")
            return sigDict != nil
        }
    }

    func syncMountDeveloperImage(image: Data, signature: Data) throws {
        try withService(
            serviceIdentifier: "com.apple.mobile.mobile_image_mounter",
            create: mobile_image_mounter_new,
            cleanup: mobile_image_mounter_free
        ) { mounter in
            try signature.withUnsafeBytes { sigBuf in
                guard let sigPtr = sigBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    throw LibimobiledeviceGatewayError(.serviceError, reason: "Invalid signature buffer")
                }
                var resultPlist: plist_t? = nil
                let res = mobile_image_mounter_mount_image(
                    mounter,
                    "/tmp/DeveloperDiskImage.dmg",
                    sigPtr,
                    UInt32(signature.count),
                    "Developer",
                    &resultPlist
                )
                if let resultPlist = resultPlist {
                    plist_free(resultPlist)
                }
                if res != MOBILE_IMAGE_MOUNTER_E_SUCCESS {
                    throw LibimobiledeviceGatewayError(.serviceError, reason: "mobile_image_mounter_mount_image failed with code \(res.rawValue)")
                }
            }
        }
    }

    func syncMountPersonalizedDdi(image: Data, trustcache: Data, manifest: Data) throws {
        try withService(
            serviceIdentifier: "com.apple.mobile.mobile_image_mounter",
            create: mobile_image_mounter_new,
            cleanup: mobile_image_mounter_free
        ) { mounter in
            try signaturePlaceholder(image: image, trustcache: trustcache, manifest: manifest, mounter: mounter)
        }
    }

    private func signaturePlaceholder(image: Data, trustcache: Data, manifest: Data, mounter: mobile_image_mounter_client_t) throws {
        var optionsPlist: plist_t? = plist_new_dict()
        defer { if let p = optionsPlist { plist_free(p) } }

        try trustcache.withUnsafeBytes { tcBuf in
            if let tcPtr = tcBuf.baseAddress?.assumingMemoryBound(to: CChar.self) {
                let tcDataPlist = plist_new_data(tcPtr, UInt64(trustcache.count))
                plist_dict_set_item(optionsPlist, "ImageTrustCache", tcDataPlist)
            }
        }

        try manifest.withUnsafeBytes { mftBuf in
            if let mftPtr = mftBuf.baseAddress?.assumingMemoryBound(to: CChar.self) {
                let mftDataPlist = plist_new_data(mftPtr, UInt64(manifest.count))
                plist_dict_set_item(optionsPlist, "ImageManifest", mftDataPlist)
            }
        }

        var resultPlist: plist_t? = nil
        let res = mobile_image_mounter_mount_image_with_options(
            mounter,
            "/tmp/PersonalizedImage.dmg",
            nil,
            0,
            "Personalized",
            optionsPlist,
            &resultPlist
        )
        if let resultPlist = resultPlist {
            plist_free(resultPlist)
        }
        if res != MOBILE_IMAGE_MOUNTER_E_SUCCESS {
            throw LibimobiledeviceGatewayError(.serviceError, reason: "mobile_image_mounter_mount_image_with_options failed with code \(res.rawValue)")
        }
    }

    func syncInstallProvisioningProfile(profile: Data) throws {
        try withService(
            serviceIdentifier: "com.apple.misagent",
            create: misagent_client_new,
            cleanup: misagent_client_free
        ) { misagent in
            try profile.withUnsafeBytes { profBuf in
                guard let profPtr = profBuf.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                    throw LibimobiledeviceGatewayError(.serviceError, reason: "Invalid profile buffer")
                }
                let plistProfile = plist_new_data(profPtr, UInt64(profile.count))
                defer { if let p = plistProfile { plist_free(p) } }

                let res = misagent_install(misagent, plistProfile)
                if res != MISAGENT_E_SUCCESS {
                    throw LibimobiledeviceGatewayError(.serviceError, reason: "misagent_install failed with code \(res.rawValue)")
                }
            }
        }
    }

    func syncRemoveProvisioningProfile(id: String) throws {
        try withService(
            serviceIdentifier: "com.apple.misagent",
            create: misagent_client_new,
            cleanup: misagent_client_free
        ) { misagent in
            let res = misagent_remove(misagent, id)
            if res != MISAGENT_E_SUCCESS {
                throw LibimobiledeviceGatewayError(.serviceError, reason: "misagent_remove failed with code \(res.rawValue)")
            }
        }
    }

    func syncDumpProfiles(docsPath: String) throws -> String {
        try withService(
            serviceIdentifier: "com.apple.misagent",
            create: misagent_client_new,
            cleanup: misagent_client_free
        ) { misagent in
            var profilesPlist: plist_t? = nil
            let res = misagent_copy_all(misagent, &profilesPlist)
            if res != MISAGENT_E_SUCCESS {
                throw LibimobiledeviceGatewayError(.serviceError, reason: "misagent_copy_all failed with code \(res.rawValue)")
            }
            defer { if let p = profilesPlist { plist_free(p) } }

            var xmlPtr: UnsafeMutablePointer<CChar>? = nil
            var xmlLen: UInt32 = 0
            plist_to_xml(profilesPlist, &xmlPtr, &xmlLen)
            if let xmlPtr = xmlPtr {
                let xmlStr = String(cString: xmlPtr)
                free(xmlPtr)
                return xmlStr
            }
            return ""
        }
    }

    func syncRemoveApp(bundleId: String) throws {
        try withService(
            serviceIdentifier: "com.apple.mobile.installation_proxy",
            create: instproxy_client_new,
            cleanup: instproxy_client_free
        ) { instproxy in
            let res = instproxy_uninstall(instproxy, bundleId, nil, nil, nil)
            if res != INSTPROXY_E_SUCCESS {
                throw LibimobiledeviceGatewayError(.serviceError, reason: "instproxy_uninstall failed with code \(res.rawValue)")
            }
        }
    }

    func syncYeetAppAfc(bundleId: String, ipaBytes: Data) throws {
        try withService(
            serviceIdentifier: "com.apple.afc",
            create: afc_client_new,
            cleanup: afc_client_free
        ) { afc in
            let remotePath = "PublicStaging/\(bundleId).ipa"
            var handle: UInt64 = 0
            let openRes = afc_file_open(afc, remotePath, AFC_FOPEN_RW, &handle)
            guard openRes == AFC_E_SUCCESS, handle != 0 else {
                throw LibimobiledeviceGatewayError(.serviceError, reason: "afc_file_open failed with code \(openRes.rawValue)")
            }
            defer { _ = afc_file_close(afc, handle) }

            try ipaBytes.withUnsafeBytes { rawBuf in
                guard let baseAddr = rawBuf.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                    throw LibimobiledeviceGatewayError(.serviceError, reason: "Invalid IPA buffer")
                }
                var bytesWritten: UInt32 = 0
                let writeRes = afc_file_write(afc, handle, baseAddr, UInt32(ipaBytes.count), &bytesWritten)
                if writeRes != AFC_E_SUCCESS {
                    throw LibimobiledeviceGatewayError(.serviceError, reason: "afc_file_write failed with code \(writeRes.rawValue)")
                }
            }
        }
    }

    func syncInstallIpa(bundleId: String) throws {
        try withService(
            serviceIdentifier: "com.apple.mobile.installation_proxy",
            create: instproxy_client_new,
            cleanup: instproxy_client_free
        ) { instproxy in
            let remotePath = "PublicStaging/\(bundleId).ipa"
            let res = instproxy_install(instproxy, remotePath, nil, nil, nil)
            if res != INSTPROXY_E_SUCCESS {
                throw LibimobiledeviceGatewayError(.serviceError, reason: "instproxy_install failed with code \(res.rawValue)")
            }
        }
    }

    func syncWipeContainer(identifier: String) throws {
        try withService(
            serviceIdentifier: "com.apple.mobile.house_arrest",
            create: house_arrest_client_new,
            cleanup: house_arrest_client_free
        ) { ha in
            let res = house_arrest_send_command(ha, "VendContainer", identifier)
            if res != HOUSE_ARREST_E_SUCCESS {
                throw LibimobiledeviceGatewayError(.serviceError, reason: "house_arrest_send_command failed with code \(res.rawValue)")
            }
            var resultDict: plist_t? = nil
            let gRes = house_arrest_get_result(ha, &resultDict)
            if let resultDict = resultDict {
                plist_free(resultDict)
            }
            if gRes != HOUSE_ARREST_E_SUCCESS {
                throw LibimobiledeviceGatewayError(.serviceError, reason: "house_arrest_get_result failed with code \(gRes.rawValue)")
            }
        }
    }

    func syncDebugApp(appId: String) throws {
        try withService(
            serviceIdentifier: "com.apple.debugserver",
            create: debugserver_client_new,
            cleanup: debugserver_client_free
        ) { ds in
            debugLog("[LibimobiledeviceGateway] debugApp connected to debugserver for \(appId)")
        }
    }

    func syncDebugProcess(pid: UInt32) throws {
        try withService(
            serviceIdentifier: "com.apple.debugserver",
            create: debugserver_client_new,
            cleanup: debugserver_client_free
        ) { ds in
            debugLog("[LibimobiledeviceGateway] debugProcess connected to debugserver for PID \(pid)")
        }
    }

    func syncPerformHeartbeat(interval: UInt64, newInterval: inout UInt64) throws {
        try withService(
            serviceIdentifier: "com.apple.mobile.heartbeat",
            create: heartbeat_client_new,
            cleanup: heartbeat_client_free
        ) { hb in
            var plist: plist_t? = plist_new_dict()
            defer { if let p = plist { plist_free(p) } }
            plist_dict_set_item(plist, "Command", plist_new_string("Pico"))

            let sRes = heartbeat_send(hb, plist)
            if sRes != HEARTBEAT_E_SUCCESS {
                throw LibimobiledeviceGatewayError(.serviceError, reason: "heartbeat_send failed with code \(sRes.rawValue)")
            }

            var respPlist: plist_t? = nil
            let rRes = heartbeat_receive_with_timeout(hb, &respPlist, 5000)
            if let respPlist = respPlist {
                defer { plist_free(respPlist) }
                var intervalVal: UInt64 = 0
                if let intNode = plist_dict_get_item(respPlist, "Interval") {
                    plist_get_uint_val(intNode, &intervalVal)
                    newInterval = intervalVal
                    return
                }
            }
            if rRes != HEARTBEAT_E_SUCCESS {
                throw LibimobiledeviceGatewayError(.serviceError, reason: "heartbeat_receive_with_timeout failed with code \(rRes.rawValue)")
            }
            newInterval = interval
        }
    }

    func syncAfcListDirectory(bundleId: String, path: String) throws -> [String] {
        try withService(
            serviceIdentifier: "com.apple.afc",
            create: afc_client_new,
            cleanup: afc_client_free
        ) { afc in
            var dirList: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = nil
            let res = afc_read_directory(afc, path, &dirList)
            if res != AFC_E_SUCCESS {
                throw LibimobiledeviceGatewayError(.serviceError, reason: "afc_read_directory failed with code \(res.rawValue)")
            }
            defer {
                if let dirList = dirList {
                    afc_dictionary_free(dirList)
                }
            }

            var entries: [String] = []
            if let dirList = dirList {
                var idx = 0
                while let entry = dirList[idx] {
                    entries.append(String(cString: entry))
                    idx += 1
                }
            }
            return entries
        }
    }

    func syncAfcReadFile(bundleId: String, path: String) throws -> Data {
        try withService(
            serviceIdentifier: "com.apple.afc",
            create: afc_client_new,
            cleanup: afc_client_free
        ) { afc in
            var handle: UInt64 = 0
            let openRes = afc_file_open(afc, path, AFC_FOPEN_RDONLY, &handle)
            guard openRes == AFC_E_SUCCESS, handle != 0 else {
                throw LibimobiledeviceGatewayError(.serviceError, reason: "afc_file_open failed with code \(openRes.rawValue)")
            }
            defer { _ = afc_file_close(afc, handle) }

            var buffer = Data()
            let chunkSize: UInt32 = 65536
            var temp = [UInt8](repeating: 0, count: Int(chunkSize))

            while true {
                var bytesRead: UInt32 = 0
                let readRes = temp.withUnsafeMutableBytes { rawBuf in
                    guard let ptr = rawBuf.baseAddress?.assumingMemoryBound(to: CChar.self) else { return AFC_E_INTERNAL_ERROR }
                    return afc_file_read(afc, handle, ptr, chunkSize, &bytesRead)
                }
                if readRes != AFC_E_SUCCESS {
                    throw LibimobiledeviceGatewayError(.serviceError, reason: "afc_file_read failed with code \(readRes.rawValue)")
                }
                if bytesRead == 0 { break }
                buffer.append(temp, count: Int(bytesRead))
            }
            return buffer
        }
    }

    func syncAfcGetFileInfo(bundleId: String, path: String) throws -> (isDirectory: Bool, fileSize: Int64) {
        try withService(
            serviceIdentifier: "com.apple.afc",
            create: afc_client_new,
            cleanup: afc_client_free
        ) { afc in
            var infoList: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = nil
            let res = afc_get_file_info(afc, path, &infoList)
            if res != AFC_E_SUCCESS {
                throw LibimobiledeviceGatewayError(.serviceError, reason: "afc_get_file_info failed with code \(res.rawValue)")
            }
            defer {
                if let infoList = infoList {
                    afc_dictionary_free(infoList)
                }
            }

            var isDir = false
            var fileSize: Int64 = 0

            if let infoList = infoList {
                var idx = 0
                while let keyPtr = infoList[idx], let valPtr = infoList[idx + 1] {
                    let key = String(cString: keyPtr)
                    let val = String(cString: valPtr)
                    if key == "st_ifmt" && val == "S_IFDIR" {
                        isDir = true
                    } else if key == "st_size" {
                        fileSize = Int64(val) ?? 0
                    }
                    idx += 2
                }
            }
            return (isDirectory: isDir, fileSize: fileSize)
        }
    }
}

// Async FFI Dispatcher Extensions
extension LibimobiledeviceGateway {
    public func start(pairingFileContent: String) async throws {
        try await withFFIDispatch {
            try self.syncStart(pairingFileContent: pairingFileContent)
        }
    }

    public func fetchUDID() async throws -> String? {
        try await withFFIDispatch {
            try self.syncFetchUDID()
        }
    }

    public func getLockdownValue(key: String) async throws -> String? {
        try await withFFIDispatch {
            try self.syncGetLockdownValue(key: key)
        }
    }

    public func installProvisioningProfile(profile: Data) async throws {
        try await withFFIDispatch {
            try self.syncInstallProvisioningProfile(profile: profile)
        }
    }

    public func removeProvisioningProfile(id: String) async throws {
        try await withFFIDispatch {
            try self.syncRemoveProvisioningProfile(id: id)
        }
    }

    public func removeApp(bundleId: String) async throws {
        try await withFFIDispatch {
            try self.syncRemoveApp(bundleId: bundleId)
        }
    }

    public func yeetAppAfc(bundleId: String, ipaBytes: Data) async throws {
        try await withFFIDispatch {
            try self.syncYeetAppAfc(bundleId: bundleId, ipaBytes: ipaBytes)
        }
    }

    public func installIpa(bundleId: String) async throws {
        try await withFFIDispatch {
            try self.syncInstallIpa(bundleId: bundleId)
        }
    }

    public func debugApp(appId: String) async throws {
        try await withFFIDispatch {
            try self.syncDebugApp(appId: appId)
        }
    }

    public func debugProcess(pid: UInt32) async throws {
        try await withFFIDispatch {
            try self.syncDebugProcess(pid: pid)
        }
    }

    public func dumpProfiles(docsPath: String) async throws -> String {
        try await withFFIDispatch {
            try self.syncDumpProfiles(docsPath: docsPath)
        }
    }

    public func performHeartbeat(interval: UInt64) async throws -> UInt64 {
        try await withFFIDispatch {
            var newInterval: UInt64 = 0
            try self.syncPerformHeartbeat(interval: interval, newInterval: &newInterval)
            return newInterval > 0 ? newInterval : 1000
        }
    }

    public func mountPersonalizedDdi(image: Data, trustcache: Data, manifest: Data) async throws {
        try await withFFIDispatch {
            try self.syncMountPersonalizedDdi(image: image, trustcache: trustcache, manifest: manifest)
        }
    }

    public func isDDIMounted() async throws -> Bool {
        try await withFFIDispatch {
            try self.syncIsDDIMounted()
        }
    }

    public func mountDeveloperImage(image: Data, signature: Data) async throws {
        try await withFFIDispatch {
            try self.syncMountDeveloperImage(image: image, signature: signature)
        }
    }

    public func startWirelessPair(
        hostName: String,
        hostModel: String,
        outPath: String,
        onReady: @escaping @Sendable (String, UInt16, [String: String]) -> Void,
        onPin: @escaping @Sendable (String) -> Void
    ) async throws -> WirelessPairPairedDevice {
        throw LibimobiledeviceGatewayError(.unsupportedOperation, reason: "startWirelessPair (RemotePairing is not supported on pure Lockdown gateway)")
    }

    public func afcListDirectory(bundleId: String, path: String) async throws -> [String] {
        try await withFFIDispatch {
            try self.syncAfcListDirectory(bundleId: bundleId, path: path)
        }
    }

    public func afcReadFile(bundleId: String, path: String) async throws -> Data {
        try await withFFIDispatch {
            try self.syncAfcReadFile(bundleId: bundleId, path: path)
        }
    }

    public func afcGetFileInfo(bundleId: String, path: String) async throws -> (isDirectory: Bool, fileSize: Int64) {
        try await withFFIDispatch {
            try self.syncAfcGetFileInfo(bundleId: bundleId, path: path)
        }
    }

    public func wipeContainer(identifier: String) async throws {
        try await withFFIDispatch {
            try self.syncWipeContainer(identifier: identifier)
        }
    }
}
