//
//  MinimuxerInternalError.swift
//  Minimuxer
//
//  Created by Magesh K on 4/7/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import RustBridge

internal enum MinimuxerInternalError: Error, LocalizedError {
    case deviceEndpointNotInitialized
    case ifaceNotRefreshed
    case pairingFailed(String)

    var errorDescription: String? {
        switch self {
        case .deviceEndpointNotInitialized: return "DeviceEndpointNotInitialized"
        case .ifaceNotRefreshed: return "IfaceNotRefreshed"
        case .pairingFailed(let msg): return "PairingFailed(\(msg))"
        }
    }
}

// MARK: - Internal Helpers

@inline(__always)
internal func adaptingBridgeError<T>(_ action: () throws -> T) throws -> T {
    do {
        return try action()
    } catch let error as RustBridgeError {
        switch error {
        case .pairingFileRejected:
            throw MinimuxerError.PairingFile
        case .connectionReset:
            throw MinimuxerError.NoConnection
        case .unknown:
            throw MinimuxerError.bridgeError(error)
        }
    } catch {
        throw error
    }
}
