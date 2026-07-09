//
//  NetworkObserverService.swift
//  Minimuxer
//
//  Original Rust Implementation by @jkcoxson
//  Swift Port created by Magesh K on 02/03/26.
//

import Network
import Foundation

final internal class NetworkObserverService: NetworkObserverAPI, @unchecked Sendable {

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "net.monitor")
    private let state = State()
    
    private actor State {
        var started = false
        var observationTask: Task<Void, Never>? = nil
        
        func with<T>(_ body: (isolated State) throws -> T) rethrows -> T {
            try body(self)
        }
    }

    @discardableResult
    func start() async -> Bool {
        let alreadyStarted = await state.with { $0.started }
        guard !alreadyStarted else {
            verboseLog("[minimuxer] [net] monitor already started")
            return false
        }

        await state.with { $0.started = true }
        verboseLog("[minimuxer] [net] monitor started")

        let paths = AsyncStream<NWPath> { [weak self] continuation in
            guard let self = self else {
                continuation.finish()
                return
            }
            self.monitor.pathUpdateHandler = { path in
                continuation.yield(path)
            }
        }

        self.monitor.start(queue: self.queue)

        let task = Task.detached { [weak self] in
            for await path in paths {
                verboseLog("[minimuxer] [net] path changed, status: \(path.status)")
                guard path.status == .satisfied else { continue }
                await self?.refreshEndpoint()
            }
        }
        await state.with { $0.observationTask = task }

        return true
    }
    
    func refreshEndpoint() async {
        verboseLog("[minimuxer] [net] refreshing interfaces list and peers")
        let changed = await IfaceScanner.shared.refresh()
        guard changed else { return }

        verboseLog("[minimuxer] [net] retrive the first uTun vpn interface info")
        if let info = try? await IfaceScanner.shared.probableVPN() {
            let peerIP = await info.peerIP
            verboseLog("[minimuxer] [net] vpn: \(info) peer: \(peerIP ?? "nil")")

            if let peer = peerIP {
                verboseLog("[minimuxer] [net] update the device endpoint with discovered peer on the vpn interface")
                await DeviceEndpoint.shared.update(peer)
                MuxerService.notifyDeviceAttached(deviceIP: peer)
            } else {
                verboseLog("[minimuxer] [net] peer not available for \(info.name)")
                await DeviceEndpoint.shared.clear()
                MuxerService.notifyDeviceDetached()
            }
        } else {
            verboseLog("[minimuxer] [net] no SideVPN endpoint detected")
            await DeviceEndpoint.shared.clear()
            MuxerService.notifyDeviceDetached()
        }
    }
    
    @discardableResult
    func stop() async -> Bool {
        let isStarted = await state.with { $0.started }
        guard isStarted else {
            verboseLog("[minimuxer] [net] monitor already stopped")
            return false
        }

        self.monitor.cancel()
        await state.with {
            $0.observationTask?.cancel()
            $0.observationTask = nil
            $0.started = false
        }
        
        verboseLog("[minimuxer] [net] monitor stopped")
        return true
    }
    
    var isWifiSatisfied: Bool {
        let path = monitor.currentPath
        return path.status == .satisfied && path.usesInterfaceType(.wifi)
    }
    
    var isWiredSatisfied: Bool {
        let path = monitor.currentPath
        return path.status == .satisfied && path.usesInterfaceType(.wiredEthernet)
    }
    
    var isBridgeSatisfied: Bool {
        let path = monitor.currentPath
        if path.status == .satisfied && path.usesInterfaceType(.other) {
            return true
        }
        
        let semaphore = DispatchSemaphore(value: 0)
        var interfaces: Set<NetInfo> = []
        Task {
            interfaces = await IfaceScanner.shared.interfaces
            semaphore.signal()
        }
        semaphore.wait()
        
        return interfaces.contains { info in
            info.name.lowercased().contains("bridge") ||
            info.name.lowercased().contains("ap")
        }
    }

    /// True when at least one `utun*` interface is active (userspace VPN — LocalDevVPN).
    var isUTunAvailable: Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var interfaces: Set<NetInfo> = []
        Task {
            interfaces = await IfaceScanner.shared.interfaces
            semaphore.signal()
        }
        semaphore.wait()
        return interfaces.contains { $0.name.hasPrefix("utun") }
    }

    /// True when at least one `ipsec*` interface is active (IKEv2/IPSec kernel VPN).
    var isIKEv2IPSecAvailable: Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var interfaces: Set<NetInfo> = []
        Task {
            interfaces = await IfaceScanner.shared.interfaces
            semaphore.signal()
        }
        semaphore.wait()
        return interfaces.contains { $0.name.hasPrefix("ipsec") }
    }
}
