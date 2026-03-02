//
//  DeviceEndpoint.swift
//  Minimuxer
//
//  Created by Magesh K on 02/03/26.
//

import Foundation

final class DeviceEndpoint {

    static let shared = DeviceEndpoint()

    private let lock = NSLock()
    private var _ip: String?

    private init() {}

    public func ip() throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard let ip = _ip else { throw DeviceEndpointError.notInitialized }
        return ip
    }

    public func update(_ newIP: String) {
        lock.lock(); defer { lock.unlock() }
        _ip = newIP
        print("[minimuxer] device endpoint updated -> \(newIP)")
    }

    public var isInitialized: Bool {
        lock.lock(); defer { lock.unlock() }
        return _ip != nil
    }
}

enum DeviceEndpointError: Error {
    case notInitialized
}
