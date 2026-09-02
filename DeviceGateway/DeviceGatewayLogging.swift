//
//  DeviceGatewayLogging.swift
//  Minimuxer
//
//  Created by Magesh K on 22/08/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation

public enum DeviceGatewayLogging {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var _isLoggingEnabled: Bool = true

    public static var isLoggingEnabled: Bool {
        lock.withLock { _isLoggingEnabled }
    }

    public static func setLogging(_ enabled: Bool) {
        lock.withLock { _isLoggingEnabled = enabled }
    }
}

private struct LogFormatConfig: Sendable {
    var dateFormat: String = "%Y-%m-%dT%H:%M:%S"
    var locale: String = "en_US_POSIX"
}

private func getFormattedTimestamp(config: LogFormatConfig = LogFormatConfig()) -> String {
    var tv = timeval()
    gettimeofday(&tv, nil)
    var tm_info = tm()
    localtime_r(&tv.tv_sec, &tm_info)
    let ms = Int32(tv.tv_usec / 1000)

    var timeBuf = [CChar](repeating: 0, count: 64)
    let len = strftime(&timeBuf, timeBuf.count - 5, config.dateFormat, &tm_info)
    if len > 0 {
        timeBuf[len] = 46 // '.'
        timeBuf[len + 1] = CChar(48 + (ms / 100))
        timeBuf[len + 2] = CChar(48 + ((ms / 10) % 10))
        timeBuf[len + 3] = CChar(48 + (ms % 10))
        timeBuf[len + 4] = 0
        return String(cString: timeBuf)
    }
    return ""
}

private func getTag(level: String, config: LogFormatConfig = LogFormatConfig()) -> String {
    let timestamp = getFormattedTimestamp(config: config)
    return "\(timestamp) \(level): "
}

public func debugLog(_ text: @autoclosure () -> String) {
    let message = text()
    if !message.isEmpty && message.allSatisfy({ $0 == "\n" || $0 == "\r" }) {
        print(message, terminator: "")
    } else {
        print("\(getTag(level: "[D]"))\(message)")
    }
}

public func verboseLog(_ text: @autoclosure () -> String) {
    if DeviceGatewayLogging.isLoggingEnabled {
        let message = text()
        if !message.isEmpty && message.allSatisfy({ $0 == "\n" || $0 == "\r" }) {
            print(message, terminator: "")
        } else {
            print("\(getTag(level: "[V]"))\(message)")
        }
    }
}
