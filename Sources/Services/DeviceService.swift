//
//  DeviceService.swift
//  Minimuxer
//
//  Original Rust Implementation by @jkcoxson
//  Swift Port created by Magesh K on 02/03/26.
//

import Foundation
import RustBridge

internal class DeviceService {
    private let rustDevice: RustDevice
    internal var instance: RustDevice { rustDevice }

    init(rustDevice: RustDevice) { self.rustDevice = rustDevice }

    static func getFirstDevice() throws -> DeviceService {
        var remaining = MinimuxerConstants.deviceFetchTimeoutMs
        let sleep = MinimuxerConstants.deviceFetchSleepMs

        while remaining > 0 {
            if let rd = RustDevice.fetchFirst() {
                return DeviceService(rustDevice: rd)
            }
            Thread.sleep(forTimeInterval: Double(sleep) / 1000.0)
            remaining = remaining >= UInt16(sleep) ? remaining - UInt16(sleep) : 0
        }
        debugLog("[minimuxer] ERROR: Couldn't fetch first device (timed out)")
        throw MinimuxerError.NoDevice
    }

    func getUDID() -> String? { rustDevice.getUDID() }
}
