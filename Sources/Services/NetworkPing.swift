//
//  NetworkPing.swift
//  Minimuxer
//
//  Created by Magesh K on 22/08/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation

final internal class NetworkPing {
    /// Probes whether a TCP port is open on IPv4 or IPv6 with a millisecond timeout.
    static func testTCP(ip: String, port: UInt16, timeoutMs: Int = 100) -> Bool {
        guard !ip.isEmpty else { return false }

        let isIPv6 = ip.contains(":")
        let family = isIPv6 ? AF_INET6 : AF_INET
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        // Non-blocking mode
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        if isIPv6 {
            var addr = sockaddr_in6()
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = port.bigEndian
            guard inet_pton(AF_INET6, ip, &addr.sin6_addr) == 1 else { return false }
            _ = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return false }
            _ = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let result = poll(&pfd, 1, Int32(timeoutMs))

        // Ensure connected and no error flags (POLLERR / POLLHUP / POLLNVAL)
        let hasOutput = (pfd.revents & Int16(POLLOUT)) != 0
        let hasError = (pfd.revents & (Int16(POLLERR) | Int16(POLLHUP) | Int16(POLLNVAL))) != 0

        if result > 0 && hasOutput && !hasError {
            // Verify socket error code directly
            var socketError: Int32 = 0
            var errorLen = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &errorLen)
            return socketError == 0
        }
        return false
    }
}
