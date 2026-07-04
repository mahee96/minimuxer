//
//  Provision.swift
//  Minimuxer
//
//  Original Rust Implementation by @jkcoxson
//  Swift Port created by Magesh K on 02/03/26.
//

import Foundation
import RustBridge

internal protocol ProvisionProvider {
    func installProvisioningProfile(profile: Data) throws;
    func removeProvisioningProfile(id: String) throws;
    func dumpProfiles(docsPath: String) throws -> String;
}

final internal class Provision {
    static var provider: ProvisionProvider?;
    
    private static func getProvider() -> any ProvisionProvider {
        if let provider {
            return provider
        } else {
            if MuxerService.isrppairing {
                provider = RPProvision()
            } else {
                provider = LockDownProvision()
            }
        }
        return provider!
    }
    
    static func installProvisioningProfile(profile: Data) throws {
        try getProvider().installProvisioningProfile(profile: profile)
    }
    static func removeProvisioningProfile(id: String) throws {
        try getProvider().removeProvisioningProfile(id: id)
    }
    static func dumpProfiles(docsPath: String) throws -> String {
        try getProvider().dumpProfiles(docsPath: docsPath)
    }
}

final internal class LockDownProvision: ProvisionProvider {
    func installProvisioningProfile(profile: Data) throws {
        verboseLog("[minimuxer] Installing provisioning profile")
        let device = try DeviceService.getFirstDevice()
        guard let misagent = RustMisagent.connect(device: device.instance, label: "minimuxer-install-prov") else {
            debugLog("[minimuxer] ERROR: Failed to start misagent client")
            throw MinimuxerError.CreateMisagent
        }

        if !misagent.install(profileData: profile) {
            debugLog("[minimuxer] ERROR: Unable to install provisioning profile")
            throw MinimuxerError.ProfileInstall
        }
        verboseLog("[minimuxer] Successfully installed provisioning profile!")
    }

    func removeProvisioningProfile(id: String) throws {
        verboseLog("[minimuxer] Removing profile with ID: \(id)")
        let device = try DeviceService.getFirstDevice()
        guard let misagent = RustMisagent.connect(device: device.instance, label: "minimuxer-install-prov") else {
            debugLog("[minimuxer] ERROR: Failed to start misagent client")
            throw MinimuxerError.CreateMisagent
        }

        if !misagent.remove(profileId: id) {
            debugLog("[minimuxer] ERROR: Unable to remove provisioning profile")
            throw MinimuxerError.ProfileRemove
        }
        verboseLog("[minimuxer] Successfully removed profile")
    }

    func dumpProfiles(docsPath: String) throws -> String {
        verboseLog("[minimuxer] Dumping profiles")
        let device = try DeviceService.getFirstDevice()
        guard let misagent = RustMisagent.connect(device: device.instance, label: "minimuxer-install-prov") else {
            debugLog("[minimuxer] ERROR: Failed to start misagent client")
            throw MinimuxerError.CreateMisagent
        }

        guard let rawPlistStr = misagent.copyAll() else {
            debugLog("[minimuxer] ERROR: Unable to copy profiles from misagent")
            throw MinimuxerError.ProfileRemove
        }

        // Parse the plist XML string returned by the bridge
        guard let rawData = rawPlistStr.data(using: .utf8),
              let rawProfiles = try? PropertyListSerialization.propertyList(from: rawData, options: [], format: nil) as? [Any] else {
            throw MinimuxerError.ProfileRemove
        }

        let path = docsPath.hasPrefix("file://") ? String(docsPath.dropFirst(7)) : docsPath
        let dumpDir = "\(path)/PROVISION"
        try? FileManager.default.createDirectory(atPath: dumpDir, withIntermediateDirectories: true)

        let xmlPrefix = "<?xml version=".data(using: .utf8)!
        let xmlSuffix = "</plist>".data(using: .utf8)!

        for (i, profileObj) in rawProfiles.enumerated() {
            guard let profileData = profileObj as? Data else { continue }

            guard let prefixRange = profileData.range(of: xmlPrefix) else { continue }
            guard let suffixRange = profileData.range(of: xmlSuffix, options: [], in: prefixRange.lowerBound..<profileData.count) else { continue }

            let plistBytes = profileData.subdata(in: prefixRange.lowerBound..<suffixRange.upperBound)

            if let innerPlist = try? PropertyListSerialization.propertyList(from: plistBytes, options: [], format: nil) as? [String: Any],
               let uuid = innerPlist["UUID"] as? String {
                try profileData.write(to: URL(fileURLWithPath: "\(dumpDir)/\(uuid).mobileprovision"))
                try plistBytes.write(to: URL(fileURLWithPath: "\(dumpDir)/\(uuid).plist"))
            } else {
                try profileData.write(to: URL(fileURLWithPath: "\(dumpDir)/unknown_\(i).mobileprovision"))
            }
        }
        verboseLog("[minimuxer] Profile dump success")
        return dumpDir
    }
}


final internal class RPProvision: ProvisionProvider {
    func dumpProfiles(docsPath: String) throws -> String {
        let path = docsPath.hasPrefix("file://") ? String(docsPath.dropFirst(7)) : docsPath
        try adaptingBridgeError {
            try RustIdevice.dumpProfiles(path)
        }
        return "\(path)/PROVISION"
    }
    
    func installProvisioningProfile(profile: Data) throws {
        try adaptingBridgeError {
            try RustIdevice.installProvisioningProfile(profile)
        }
    }
    
    func removeProvisioningProfile(id: String) throws {
        try adaptingBridgeError {
            try RustIdevice.removeProvisioningProfile(id: id)
        }
    }
}
