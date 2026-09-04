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
    var plist: [String: any Sendable] { get }
}

public struct RPPairingFile: PairingFile {
    public let rawContent: String
    public let rawData: Data
    public let mode: PairingProtocol = .rppairing
    public let plist: [String: any Sendable]
    public let identifier: String
    public let publicKey: Data?
    public let privateKey: Data?

    public init(content: String, plist: [String: any Sendable], data: Data) throws {
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
    public let plist: [String: any Sendable]
    public let udid: String
    public let systemBUID: String
    public let hostID: String?
    public let wifiMACAddress: String?
    public let hostCertificate: Data?
    public let rootCertificate: Data?
    public let deviceCertificate: Data?

    public init(content: String, plist: [String: any Sendable], data: Data) throws {
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
        guard let rawPlist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw PairingError.invalidPlist("PropertyListSerialization failed")
        }
        let plist = toSendableDictionary(rawPlist)
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

    private static func toSendableDictionary(_ dict: [String: Any]) -> [String: any Sendable] {
        var result: [String: any Sendable] = [:]
        for (k, v) in dict {
            if let s = v as? String { result[k] = s }
            else if let d = v as? Data { result[k] = d }
            else if let dt = v as? Date { result[k] = dt }
            else if let n = v as? NSNumber { result[k] = n }
            else if let b = v as? Bool { result[k] = b }
            else if let subDict = v as? [String: Any] { result[k] = toSendableDictionary(subDict) }
        }
        return result
    }
}
