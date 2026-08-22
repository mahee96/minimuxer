//
//  PairingProtocol.swift
//  Minimuxer
//
//  Created by Magesh K on 7/8/26.
//  Copyright © 2026 SideStore. All rights reserved.
//
import Foundation

public enum PairingProtocol: String, Codable, CustomStringConvertible, Sendable {
    case rppairing = "rppairing"
    case lockdown = "lockdown"
    case unknown = "unknown"
    
    public var description: String {
        return self.rawValue
    }


    public static func validatePairingFile(from plist: [String: Any]?) throws -> PairingProtocol {
        guard let plist = plist else {
            throw DeviceGatewayError(.invalidPairingFile, reason: "The file could not be parsed as a property list (plist).")
        }

        let requiredRPKeys = ["private_key", "public_key", "identifier"]
        let missingRPKeys = requiredRPKeys.filter { plist[$0] == nil }
        if missingRPKeys.isEmpty {
            return .rppairing
        }

        let requiredLockdownKeys = [
            "WiFiMACAddress", "SystemBUID", "RootPrivateKey", "HostPrivateKey",
            "HostID", "RootCertificate", "UDID", "EscrowBag", "HostCertificate",
            "DeviceCertificate"
        ]
        let missingLockdownKeys = requiredLockdownKeys.filter { plist[$0] == nil }
        if missingLockdownKeys.isEmpty {
            return .lockdown
        }

        throw DeviceGatewayError(
            .invalidPairingFile,
            reason: "The pairing file is incomplete. Missing Remote Pairing attributes: \(missingRPKeys.joined(separator: ", ")); missing Lockdown attributes: \(missingLockdownKeys.joined(separator: ", "))."
        )
    }
}
