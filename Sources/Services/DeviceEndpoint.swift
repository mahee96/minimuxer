//
//  DeviceEndpoint.swift
//  Minimuxer
//
//  Original Rust Implementation by @jkcoxson
//  Swift Port created by Magesh K on 02/03/26.
//

import Foundation

final internal class DeviceEndpoint: @unchecked Sendable {

    static let shared = DeviceEndpoint()

    private let lock = NSLock()
    private var _ip: String? = nil

    private init() {}

    func ip() throws -> String {
        try lock.withLock {
            guard let ip = _ip else { throw MinimuxerInternalError.deviceEndpointNotInitialized }
            return ip
        }
    }

    func update(_ newIP: String) {
        lock.withLock {
            _ip = newIP
        }
        verboseLog("[minimuxer] device endpoint updated -> \(newIP)")
    }

    func clear() {
        lock.withLock {
            _ip = nil
        }
        verboseLog("[minimuxer] device endpoint cleared -> nil")
    }

    var isInitialized: Bool {
        lock.withLock {
            _ip != nil
        }
    }
}
