//
//  EMProxyImpl.swift
//  Minimuxer
//
//  Created by Magesh K on 12/8/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import EMProxy

public enum EMProxyError: Error, LocalizedError, CustomStringConvertible, Equatable, Sendable {
    case invalidBindAddressPointer
    case invalidUTF8String
    case invalidSocketAddress(String)
    case unknownError(Int32)

    public var description: String {
        switch self {
        case .invalidBindAddressPointer:
            return "Invalid bind address pointer"
        case .invalidUTF8String:
            return "Failed to convert bind address to UTF-8"
        case .invalidSocketAddress(let addr):
            return "Invalid IPv4 socket address format: \(addr)"
        case .unknownError(let code):
            return "EMProxy start error code: \(code)"
        }
    }

    public var errorDescription: String? {
        return description
    }
}

public final class EMProxyImpl: EMProxyAPI {
    public init() {
        set_log_callback { level, msgPtr in
            guard let msgPtr = msgPtr else { return false }
            let msg = "[em_proxy] \(String(cString: msgPtr))"
            if level <= 1 {
                verboseLog(msg)
            } else {
                debugLog(msg)
            }
            return true
        }
    }

    public func start(host: String, port: UInt16) async throws {
        let address = "\(host):\(port)"
        switch start_emotional_damage(address) {
        case 0:
            return
        case -1:
            throw EMProxyError.invalidBindAddressPointer
        case -2:
            throw EMProxyError.invalidUTF8String
        case -3:
            throw EMProxyError.invalidSocketAddress(address)
        case let err:
            throw EMProxyError.unknownError(err)
        }
    }

    public func stop() async {
        stop_emotional_damage()
    }
}
