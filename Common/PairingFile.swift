//
//  PairingFile.swift
//  MinimuxerCommon
//
//  Created by Magesh K on 03/09/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation

public protocol PairingFile: Sendable {
    var rawContent: String { get }
    var rawData: Data { get }
    var mode: PairingProtocol { get }
    var plist: [String: Any] { get }
    var deviceIdentifier: String { get }
}

public struct RPPairingFile: PairingFile {
    public let rawContent: String
    public let rawData: Data
    public let mode: PairingProtocol = .rppairing
    public let plist: [String: Any]
    public let identifier: String
    public let publicKey: Data?
    public let privateKey: Data?

    public var deviceIdentifier: String { identifier }

    public init(content: String, plist: [String: Any], data: Data) throws {
        self.rawContent = content
        self.rawData = data
        self.plist = plist
        guard let id = plist["identifier"] as? String else {
            throw PairingError.incomplete(missingRP: ["identifier"], missingLockdown: [])
        }
        self.identifier = id
        self.publicKey = plist["public_key"] as? Data
        self.privateKey = plist["private_key"] as? Data
    }
}

public struct LockdownPairingFile: PairingFile {
    public let rawContent: String
    public let rawData: Data
    public let mode: PairingProtocol = .lockdown
    public let plist: [String: Any]
    public let udid: String
    public let systemBUID: String
    public let hostID: String?
    public let wifiMACAddress: String?
    public let hostCertificate: Data?
    public let rootCertificate: Data?
    public let deviceCertificate: Data?

    public var deviceIdentifier: String { udid }

    public init(content: String, plist: [String: Any], data: Data) throws {
        self.rawContent = content
        self.rawData = data
        self.plist = plist
        guard let udid = plist["UDID"] as? String,
              let systemBUID = plist["SystemBUID"] as? String else {
            var missing: [String] = []
            if plist["UDID"] == nil { missing.append("UDID") }
            if plist["SystemBUID"] == nil { missing.append("SystemBUID") }
            throw PairingError.incomplete(missingRP: [], missingLockdown: missing)
        }
        self.udid = udid
        self.systemBUID = systemBUID
        self.hostID = plist["HostID"] as? String
        self.wifiMACAddress = plist["WiFiMACAddress"] as? String
        self.hostCertificate = plist["HostCertificate"] as? Data
        self.rootCertificate = plist["RootCertificate"] as? Data
        self.deviceCertificate = plist["DeviceCertificate"] as? Data
    }
}

public enum PairingFileParser {
    public static func parse(content: String) throws -> any PairingFile {
        guard let data = content.data(using: .utf8) else {
            throw PairingError.unreadable("UTF-8 encoding failed")
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw PairingError.invalidPlist("PropertyListSerialization failed")
        }
        let mode = try PairingProtocol.validatePairingFile(from: plist)
        switch mode {
        case .rppairing:
            return try RPPairingFile(content: content, plist: plist, data: data)
        case .lockdown:
            return try LockdownPairingFile(content: content, plist: plist, data: data)
        case .unknown:
            throw PairingError.invalidPlist("Unknown pairing file format")
        }
    }
}
