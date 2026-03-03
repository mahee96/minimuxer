//
//  IfaceScanner.swift
//  Minimuxer
//
//  Created by ny on 2/27/26.
//  Copyright © 2026 SideStore. All rights reserved.
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
        // Fast path: read the kernel routing table for the host route
        // the VPN installed through this interface. Zero network I/O.
        if let peer = IfaceScanner.shared.routingTablePeer(for: self) {
            print("[minimuxer] [iface] peer from routing table:", peer)
            return peer
        }
        print("[minimuxer] [iface] no host route found for", name)
        return nil
    }

    var networkBase: UInt32 { host & mask }
    var broadcast: UInt32 { networkBase | ~mask }

    public var description: String {
        "\(name) | ip=\(hostIP) mask=\(maskIP)"
    }
    
}

// net/route.h — rt_msghdr is not bridged to Swift
private struct rt_msghdr {
    var rtm_msglen: UInt16
    var rtm_version: UInt8
    var rtm_type: UInt8
    var rtm_index: UInt16
    var rtm_flags: Int32
    var rtm_addrs: Int32
    var rtm_pid: Int32
    var rtm_seq: Int32
    var rtm_errno: Int32
    var rtm_use: Int32
    var rtm_inits: UInt32
    var rtm_rmx: rt_metrics
}

// net/route.h — rt_metrics
private struct rt_metrics {
    var rmx_locks: UInt32
    var rmx_mtu: UInt32
    var rmx_hopcount: UInt32
    var rmx_expire: Int32
    var rmx_recvpipe: UInt32
    var rmx_sendpipe: UInt32
    var rmx_ssthresh: UInt32
    var rmx_rtt: UInt32
    var rmx_rttvar: UInt32
    var rmx_pksent: UInt32
    var rmx_state: UInt32
    var rmx_filler: (UInt32, UInt32, UInt32)
}


// net/route.h constants
private let NET_RT_DUMP: Int32 = 1
private let RTF_HOST: Int32    = 0x4      // route is a host route (/32)
private let RTF_UP: Int32      = 0x1      // route is usable

public final class TunnelConfigBinding: Sendable {
    public let setDeviceIP: @Sendable (String?) -> Void
    public let setFakeIP: @Sendable (String?) -> Void
    public let setSubnetMask: @Sendable (String?) -> Void
    public let getOverrideFakeIP: @Sendable () -> String
    public let setOverrideEffective: @Sendable (Bool) -> Void

    public init(
        setDeviceIP: @escaping @Sendable (String?) -> Void,
        setFakeIP: @escaping @Sendable (String?) -> Void,
        setSubnetMask: @escaping @Sendable (String?) -> Void,
        getOverrideFakeIP: @escaping @Sendable () -> String,
        setOverrideEffective: @escaping @Sendable (Bool) -> Void
    ) {
        self.setDeviceIP = setDeviceIP
        self.setFakeIP = setFakeIP
        self.setSubnetMask = setSubnetMask
        self.getOverrideFakeIP = getOverrideFakeIP
        self.setOverrideEffective = setOverrideEffective
    }
}


final class IfaceScanner {

    static let shared = IfaceScanner()
    private(set) var interfaces: Set<NetInfo> = []

    private var refreshed = false
    private let lock = NSLock()

    private var tunnelConfigCache: TunnelConfigBinding?

    func bindTunnelConfig(_ binding: TunnelConfigBinding) {
        tunnelConfigCache = binding
        
        // ask all observers to be refreshed
        NetworkObserver.shared.refreshEndpoint()
    }

    var cachedOverrideFakeIP: String? { tunnelConfigCache?.getOverrideFakeIP() }
    
    private init() {}

    func refresh() {
        lock.lock(); defer { lock.unlock() }
        interfaces = Self.scan()
        refreshed = true

        let vpnIface = try? probableVPN()
        tunnelConfigCache?.setDeviceIP(vpnIface?.hostIP)
        tunnelConfigCache?.setSubnetMask(vpnIface?.maskIP)
        let peerIP = vpnIface?.peerIP
        tunnelConfigCache?.setFakeIP(peerIP)
        tunnelConfigCache?.setOverrideEffective(peerIP == cachedOverrideFakeIP)
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
    
    
    // Read the IPv4 routing table via sysctl and find the host route (/32)
    // that goes through the given utun interface.
    public func routingTablePeer(for iface: NetInfo) -> String? {
        let start = Date()
        defer {
            let ms = Date().timeIntervalSince(start) * 1000
            print(String(format: "[minimuxer] [iface] routingTablePeer took %.2fms", ms))
        }
        
        if let cachedDeviceIP = cachedOverrideFakeIP,
//           let raw = ipv4UInt(cachedDeviceIP),
//           (raw & iface.mask) == iface.networkBase
            Minimuxer.testDeviceConnection(ifaddr: cachedDeviceIP)
        {
            print("[minimuxer] [iface] using user specified tunnel peer:", cachedDeviceIP)
            return cachedDeviceIP
        }
    
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_DUMP, 0]
        var needed = 0
        guard sysctl(&mib, 6, nil, &needed, nil, 0) == 0, needed > 0 else { return nil }

        var buf = [UInt8](repeating: 0, count: needed)
        guard sysctl(&mib, 6, &buf, &needed, nil, 0) == 0 else { return nil }

        var candidates: [String] = []
        var idx = 0

        while idx < needed {
            guard idx + MemoryLayout<rt_msghdr>.size <= needed else { break }
            let hdr = buf.withUnsafeBytes { $0.load(fromByteOffset: idx, as: rt_msghdr.self) }
            let msglen = Int(hdr.rtm_msglen)
            guard msglen > 0 else { break }
            defer { idx += msglen }

            guard (hdr.rtm_flags & RTF_HOST) != 0 else { continue }

            var ifnameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
            guard if_indextoname(UInt32(hdr.rtm_index), &ifnameBuf) != nil,
                  String(cString: ifnameBuf) == iface.name else { continue }

            let saOffset = idx + MemoryLayout<rt_msghdr>.size
            guard saOffset + MemoryLayout<sockaddr_in>.size <= needed else { continue }
            let sa = buf.withUnsafeBytes { $0.load(fromByteOffset: saOffset, as: sockaddr_in.self) }
            guard sa.sin_family == UInt8(AF_INET) else { continue }

            var s_addr = sa.sin_addr.s_addr
            guard s_addr != 0 else { continue }
            var out = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &s_addr, &out, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let ip = String(cString: out)

            // skip the interface's own address
            guard ip != iface.hostIP else { continue }
            candidates.append(ip)
        }

        print("[minimuxer] [iface] host routes through \(iface.name):", candidates)

        // The fake device IP is the included route — it will be in the same
        // subnet as the interface. The tunnel remote/gateway may be on a
        // different subnet entirely. Prefer the one in the same subnet.
        let inSubnet = candidates.first {
            guard let raw = ipv4UInt($0) else { return false }
            return (raw & iface.mask) == iface.networkBase
        }

        let selected = inSubnet ?? candidates.first

        if let selected {
            tunnelConfigCache?.setFakeIP(selected)
            tunnelConfigCache?.setOverrideEffective(false)
        }

        return selected
    }
    

    // MARK: selection

    func probableVPN() throws -> NetInfo? {
        try ensureReady()
        return interfaces.first { $0.name.hasPrefix("utun") }
    }

    func probableLAN() throws -> NetInfo? {
        try ensureReady()
        return interfaces.first { $0.name.hasPrefix("en") }
    }

    func vpnPatched() -> Bool {
        guard let lan = try? probableLAN(),
              let vpn = try? probableVPN()
        else { return false }

        return lan.maskIP == vpn.maskIP
    }
}

enum IfaceError: Error {
    case notRefreshed
}

@inline(__always)
private func ipv4UInt(_ str: String) -> UInt32? {
    var addr = in_addr()
    return inet_pton(AF_INET, str, &addr) == 1 ? addr.s_addr.bigEndian : nil
}
