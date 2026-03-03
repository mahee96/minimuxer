//
//  Provision.swift
//  Minimuxer
//
//  Original Rust Implementation by @jkcoxson
//  Swift Port created by Magesh K on 02/03/26.
//

import Foundation
import RustBridge

public class Provision {
    public static func installProvisioningProfile(profile: Data) throws {
        print("[minimuxer] Installing provisioning profile")
        let device = try Device.getFirstDevice()
        guard let misagent = RustMisagent.connect(device: device.internalInstance, label: "minimuxer-install-prov") else {
            print("[minimuxer] ERROR: Failed to start misagent client")
            throw MinimuxerError.CreateMisagent
        }

        if !misagent.install(profileData: profile) {
            print("[minimuxer] ERROR: Unable to install provisioning profile")
            throw MinimuxerError.ProfileInstall
        }
        print("[minimuxer] Successfully installed provisioning profile!")
    }

    public static func removeProvisioningProfile(id: String) throws {
        print("[minimuxer] Removing profile with ID: \(id)")
        let device = try Device.getFirstDevice()
        guard let misagent = RustMisagent.connect(device: device.internalInstance, label: "minimuxer-install-prov") else {
            print("[minimuxer] ERROR: Failed to start misagent client")
            throw MinimuxerError.CreateMisagent
        }

        if !misagent.remove(profileId: id) {
            print("[minimuxer] ERROR: Unable to remove provisioning profile")
            throw MinimuxerError.ProfileRemove
        }
        print("[minimuxer] Successfully removed profile")
    }

    public static func dumpProfiles(docsPath: String) throws -> String {
        print("[minimuxer] Dumping profiles")
        let device = try Device.getFirstDevice()
        guard let misagent = RustMisagent.connect(device: device.internalInstance, label: "minimuxer-install-prov") else {
            print("[minimuxer] ERROR: Failed to start misagent client")
            throw MinimuxerError.CreateMisagent
        }

        guard let rawPlistStr = misagent.copyAll() else {
            print("[minimuxer] ERROR: Unable to copy profiles from misagent")
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
        print("[minimuxer] Profile dump success")
        return dumpDir
    }
}
