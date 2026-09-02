//
//  MinimuxerLogging.swift
//  Minimuxer
//
//  Created by Magesh K on 22/08/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation

public enum MinimuxerLogging {
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
    strftime(&timeBuf, timeBuf.count, config.dateFormat, &tm_info)

    var buf = [CChar](repeating: 0, count: 96)
    snprintf(&buf, buf.count, "%s.%03d", timeBuf, ms)
    return String(cString: buf)
}

private func getTag(level: String, config: LogFormatConfig = LogFormatConfig()) -> String {
    let timestamp = getFormattedTimestamp(config: config)
    return "\(timestamp) \(level): "
}

func debugLog(_ text: @autoclosure () -> String) {
    let message = text()
    if !message.isEmpty && message.allSatisfy({ $0 == "\n" || $0 == "\r" }) {
        print(message, terminator: "")
    } else {
        print("\(getTag(level: "[D]"))\(message)")
    }
}

func verboseLog(_ text: @autoclosure () -> String) {
    if MinimuxerLogging.isLoggingEnabled {
        let message = text()
        if !message.isEmpty && message.allSatisfy({ $0 == "\n" || $0 == "\r" }) {
            print(message, terminator: "")
        } else {
            print("\(getTag(level: "[V]"))\(message)")
        }
    }
}
