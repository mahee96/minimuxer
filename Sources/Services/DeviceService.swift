//
//  DeviceService.swift
//  Minimuxer
//
//  Created by Magesh K on 02/03/26.
//

import Foundation

internal class DeviceService {
    private let udid: String

    init(udid: String) {
        self.udid = udid
    }

    static func getFirstDevice() throws -> DeviceService {
        var remaining = MinimuxerConstants.deviceFetchTimeoutMs
        let sleep = MinimuxerConstants.deviceFetchSleepMs

        while remaining > 0 {
            if let udid = try? IdeviceGateway.shared.fetchUDID() {
                return DeviceService(udid: udid)
            }
            Thread.sleep(forTimeInterval: Double(sleep) / 1000.0)
            remaining = remaining >= UInt16(sleep) ? remaining - UInt16(sleep) : 0
        }
        debugLog("[minimuxer] ERROR: Couldn't fetch first device (timed out)")
        throw MinimuxerError.NoDevice
    }

    func getUDID() -> String? {
        return udid
    }
}
