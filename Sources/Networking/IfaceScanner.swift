//
//  IfManager.swift
//

import Foundation
import Darwin

// MARK: - IPv4 helpers

@inline(__always)
private func ipv4String(_ value: UInt32) -> String? {
    var addr = in_addr(s_addr: value.bigEndian)
    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    guard inet_ntop(AF_INET, &addr, &buf, UInt32(INET_ADDRSTRLEN)) != nil else { return nil }
    return String(cString: buf)
}

@inline(__always)
private func sockaddrIPv4(_ sa: inout sockaddr) -> UInt32? {
    var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    guard getnameinfo(&sa, socklen_t(sa.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0,
          let s = String(validatingUTF8: buf) else { return nil }
    var a = in_addr()
    return inet_pton(AF_INET, s, &a) == 1 ? a.s_addr.bigEndian : nil
}

// MARK: - NetInfo

public struct NetInfo: Hashable, CustomStringConvertible {

    public let name: String
    public let hostIP: String
    public let maskIP: String

    fileprivate let host: UInt32
    fileprivate let mask: UInt32

    init?(ifa: ifaddrs) {

        guard
            let name = String(utf8String: ifa.ifa_name),
            var addr = ifa.ifa_addr?.pointee,
            var mask = ifa.ifa_netmask?.pointee,
            let host = sockaddrIPv4(&addr),
            let maskU = sockaddrIPv4(&mask),
            let hostStr = ipv4String(host),
            let maskStr = ipv4String(maskU)
        else { return nil }

        self.name = name
        self.host = host
        self.mask = maskU
        self.hostIP = hostStr
        self.maskIP = maskStr
    }
    
    var peerIP: String? {
        let base = host & mask
        let broadcast = base | ~mask

        var ip = base &+ 1
        while ip < broadcast {
            if let candidate = ipv4String(ip),
               Minimuxer.testDeviceConnection(ifaddr: candidate) {
                return candidate
            }
            ip &+= 1
        }
        return nil
    }

    var networkBase: UInt32 { host & mask }
    var broadcast: UInt32 { networkBase | ~mask }

    public var description: String {
        "\(name) | ip=\(hostIP) mask=\(maskIP)"
    }
}

// MARK: - Scanner

final class IfaceScanner {

    static let shared = IfaceScanner()
    private(set) var interfaces: Set<NetInfo> = []

    // allowed VPN networks (networkBase : subnetMask)
    private var allowedVPNNetworks: [(base: UInt32, mask: UInt32)] = []

    private var refreshed = false
    private let lock = NSLock()

    private init() {}

    // configure allowed tunnel networks
    func configureAllowedVPNs(_ networks: [(baseIP: String, maskIP: String)]) throws {
        allowedVPNNetworks = try networks.map {
            guard
                let base = ipv4UInt($0.baseIP),
                let mask = ipv4UInt($0.maskIP)
            else { throw IfaceError.invalidConfiguration }
            return (base, mask)
        }
    }

    func refresh() {
        lock.lock(); defer { lock.unlock() }
        interfaces = Self.scan()
        refreshed = true
    }

    private func ensureReady() throws {
        guard refreshed else { throw IfaceError.notRefreshed }
    }

    // MARK: scan

    private static func scan() -> Set<NetInfo> {
        var result = Set<NetInfo>()
        var head: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&head) == 0, let first = head else { return result }
        defer { freeifaddrs(head) }

        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cur {
            let e = p.pointee
            let flags = Int32(e.ifa_flags)

            let ipv4 = e.ifa_addr?.pointee.sa_family == UInt8(AF_INET)
            let active = (flags & (IFF_UP | IFF_RUNNING | IFF_LOOPBACK)) == (IFF_UP | IFF_RUNNING)

            if ipv4, active, let info = NetInfo(ifa: e) {
                print("[minimuxer] [iface]", info)
                result.insert(info)
            }

            cur = e.ifa_next
        }

        print("[minimuxer] [iface] total:", result.count)
        return result
    }

    // MARK: selection

    func probableVPN() throws -> NetInfo? {
        try ensureReady()

        return interfaces.first { iface in
            allowedVPNNetworks.contains { allowed in
                (iface.host & allowed.mask) == allowed.base &&
                iface.mask == allowed.mask
            }
        }
    }

    func probableLAN() throws -> NetInfo? {
        try ensureReady()
        return interfaces.first { $0.name.hasPrefix("en") }
    }

    func vpnPatched() -> Bool {
        guard let lan = try? probableLAN(), let vpn = try? probableVPN()
        else { return false }

        return lan.maskIP == vpn.maskIP
    }
}

enum IfaceError: Error {
    case notRefreshed
    case invalidConfiguration
}

@inline(__always)
private func ipv4UInt(_ str: String) -> UInt32? {
    var addr = in_addr()
    return inet_pton(AF_INET, str, &addr) == 1 ? addr.s_addr.bigEndian : nil
}
