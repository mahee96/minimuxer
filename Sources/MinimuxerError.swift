//
//  MinimuxerErrors.swift
//  Minimuxer
//
//  Created by Magesh K on 4/7/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
// import RustBridge

public struct MinimuxerServiceError: Error, CustomStringConvertible {
    public let component: MinimuxerComponent
    public let error: Error
    
    public var description: String {
        return "[\(component.rawValue)] \(error.localizedDescription)"
    }
}

public enum MinimuxerError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case NoDevice
    case NoConnection
    case NoVPN
    case PairingFile
    case RestartAlreadyInProgressError
    case InvalidVPN
    case InvalidPairing

    case CreateDebug
    case CreateInstproxy
    case CreateLockdown
    case CreateCoreDevice
    case CreateSoftwareTunnel
    case CreateRemoteServer
    case CreateProcessControl

    case GetLockdownValue
    case Connect
    case Close
    case XpcHandshake
    case NoService
    case InvalidProductVersion
    case LookupApps
    case FindApp
    case BundlePath
    case MaxPacket
    case WorkingDirectory
    case Argv
    case LaunchSuccess
    case Detach
    case Attach

    case CreateAfc
    case RwAfc
    case InstallApp(String)
    case UninstallApp

    case CreateMisagent
    case ProfileInstall
    case ProfileRemove

    case CreateFolder
    case DownloadImage
    case ImageLookup
    case ImageRead
    case Mount
//    case bridgeError(RustBridgeError)

    public var description: String {
        switch self {
        case .NoDevice: return "NoDevice"
        case .NoConnection: return "NoConnection"
        case .NoVPN: return "NoVPN"
        case .PairingFile: return "PairingFile"
        case .RestartAlreadyInProgressError: return "RestartAlreadyInProgressError"
        case .InvalidVPN: return "InvalidVPN"
        case .InvalidPairing: return "InvalidPairing"
        case .CreateDebug: return "CreateDebug"
        case .CreateInstproxy: return "CreateInstproxy"
        case .CreateLockdown: return "CreateLockdown"
        case .CreateCoreDevice: return "CreateCoreDevice"
        case .CreateSoftwareTunnel: return "CreateSoftwareTunnel"
        case .CreateRemoteServer: return "CreateRemoteServer"
        case .CreateProcessControl: return "CreateProcessControl"
        case .GetLockdownValue: return "GetLockdownValue"
        case .Connect: return "Connect"
        case .Close: return "Close"
        case .XpcHandshake: return "XpcHandshake"
        case .NoService: return "NoService"
        case .InvalidProductVersion: return "InvalidProductVersion"
        case .LookupApps: return "LookupApps"
        case .FindApp: return "FindApp"
        case .BundlePath: return "BundlePath"
        case .MaxPacket: return "MaxPacket"
        case .WorkingDirectory: return "WorkingDirectory"
        case .Argv: return "Argv"
        case .LaunchSuccess: return "LaunchSuccess"
        case .Detach: return "Detach"
        case .Attach: return "Attach"
        case .CreateAfc: return "CreateAfc"
        case .RwAfc: return "RwAfc"
        case .InstallApp(let msg): return "InstallApp(\(msg))"
        case .UninstallApp: return "UninstallApp"
        case .CreateMisagent: return "CreateMisagent"
        case .ProfileInstall: return "ProfileInstall"
        case .ProfileRemove: return "ProfileRemove"
        case .CreateFolder: return "CreateFolder"
        case .DownloadImage: return "DownloadImage"
        case .ImageLookup: return "ImageLookup"
        case .ImageRead: return "ImageRead"
        case .Mount: return "Mount"
//        case .bridgeError(let err): return "bridgeError(\(err))"
        }
    }

    public var errorDescription: String? {
        return self.description
    }
}

// public enum RustBridgeError: Error, LocalizedError, Equatable {
//     case pairingFileRejected(description: String)
//     case connectionReset(description: String)
//     case unknown(code: Int, description: String)
//     
//     public var errorDescription: String? {
//         switch self {
//         case .pairingFileRejected(let description):
//             return description
//         case .connectionReset(let description):
//             return description
//         case .unknown(_, let description):
//             return description
//         }
//     }
// }
