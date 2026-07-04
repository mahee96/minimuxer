//
//  Install.swift
//  Minimuxer
//
//  Original Rust Implementation by @jkcoxson
//  Swift Port created by Magesh K on 02/03/26.
//

import Foundation
import RustBridge

internal protocol InstallProvider {
    func yeetAppAfc(bundleId: String, ipaBytes: Data) throws
    func installIpa(bundleId: String) throws
    func removeApp(bundleId: String) throws
}

final internal class Install {

    static var provider: InstallProvider?;
    
    private static func getProvider() throws -> any InstallProvider {
        if let provider {
            return provider
        } else {
            if MuxerService.isrppairing {
                provider = RPInstall()
            } else {
                provider = LockDownInstall()
            }
        }
        return provider!
    }

    static func yeetAppAfc(bundleId: String, ipaBytes: Data) throws {
        try getProvider().yeetAppAfc(bundleId: bundleId, ipaBytes: ipaBytes)
    }
    static func installIpa(bundleId: String) throws {
        try getProvider().installIpa(bundleId: bundleId)
    }
    static func removeApp(bundleId: String) throws {
        try getProvider().removeApp(bundleId: bundleId)
    }
}

final internal class LockDownInstall: InstallProvider {
    func yeetAppAfc(bundleId: String, ipaBytes: Data) throws {
        verboseLog("[minimuxer] Yeeting IPA for bundle ID: \(bundleId)")

        let deviceIP = try DeviceEndpoint.shared.ip()
        verboseLog("[minimuxer] AFC: verifying device connectivity at \(deviceIP)...")
        guard Minimuxer.shared.testDeviceConnection(ifaddr: deviceIP) else {
            debugLog("[minimuxer] ERROR: DeviceService not reachable before AFC start")
            throw MinimuxerError.NoVPN
        }
        verboseLog("[minimuxer] AFC: device reachable, fetching device handle")

        let device = try DeviceService.getFirstDevice()
        verboseLog("[minimuxer] AFC: creating AFC client...")
        guard let afc = RustAfc.connect(device: device.instance, label: "minimuxer") else {
            debugLog("[minimuxer] ERROR: Could not start AFC service")
            throw MinimuxerError.CreateAfc
        }
        verboseLog("[minimuxer] AFC: client created successfully")

        let pkg = MinimuxerConstants.pkgPath
        let appDir = "./\(pkg)/\(bundleId)"
        mkdirP(appDir, afc: afc)

        if !afc.writeFile(path: "\(appDir)/app.ipa", data: ipaBytes) {
            debugLog("[minimuxer] ERROR: Unable to write IPA to device")
            throw MinimuxerError.RwAfc
        }
        verboseLog("[minimuxer] Successfully staged IPA")
    }
    
    private func mkdirP(_ path: String, afc: RustAfc) {
        var current = ""
        for part in path.split(separator: "/") {
            current += "/\(part)"
            _ = afc.mkdir(path: current)
        }
    }

    func installIpa(bundleId: String) throws {
        verboseLog("[minimuxer] Installing app for bundle ID: \(bundleId)")
        let device = try DeviceService.getFirstDevice()
        guard let inst = RustInstProxy.connect(device: device.instance, label: "ideviceinstaller") else {
            debugLog("[minimuxer] ERROR: Unable to start instproxy")
            throw MinimuxerError.CreateInstproxy
        }
        let path = "./\(MinimuxerConstants.pkgPath)/\(bundleId)/app.ipa"
        verboseLog("[minimuxer] Installing...")
        if !inst.install(path: path) {
            debugLog("[minimuxer] ERROR: Install failed")
            throw MinimuxerError.InstallApp("Failed to install")
        }
        verboseLog("[minimuxer] Install done!")
    }

    func removeApp(bundleId: String) throws {
        verboseLog("[minimuxer] Removing app: \(bundleId)")
        let device = try DeviceService.getFirstDevice()
        guard let inst = RustInstProxy.connect(device: device.instance, label: "minimuxer-remove-app") else {
            debugLog("[minimuxer] ERROR: Unable to start instproxy")
            throw MinimuxerError.CreateInstproxy
        }
        verboseLog("[minimuxer] Removing...")
        if !inst.uninstall(bundleId: bundleId) {
            debugLog("[minimuxer] ERROR: Unable to uninstall app")
            throw MinimuxerError.UninstallApp
        }
        verboseLog("[minimuxer] Remove done!")
    }
}

final internal class RPInstall: InstallProvider {
    func yeetAppAfc(bundleId: String, ipaBytes: Data) throws {
        try IdeviceGateway.shared.yeetAppAfc(bundleId: bundleId, ipaBytes: ipaBytes)
    }
    func installIpa(bundleId: String) throws {
        try IdeviceGateway.shared.installIpa(bundleId: bundleId)
    }
    func removeApp(bundleId: String) throws {
        try IdeviceGateway.shared.removeApp(bundleId: bundleId)
    }
}
