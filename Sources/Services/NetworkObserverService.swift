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
        private var started = false

        func start(monitor: NWPathMonitor, queue: DispatchQueue, pathUpdateHandler: @escaping (NWPath) -> Void) -> Bool {
            guard !started else {
                verboseLog("[minimuxer] [net] monitor already started")
                return false
            }

            monitor.pathUpdateHandler = pathUpdateHandler
            monitor.start(queue: queue)
            started = true
            verboseLog("[minimuxer] [net] monitor started")
            return true
        }

        func stop(monitor: NWPathMonitor) -> Bool {
            guard started else {
                verboseLog("[minimuxer] [net] monitor already stopped")
                return false
            }
            monitor.cancel()
            started = false
            verboseLog("[minimuxer] [net] monitor stopped")
            return true
        }
    }

    @discardableResult
    func start() -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var result = false
        Task { [weak self] in
            guard let self = self else {
                semaphore.signal()
                return
            }
            result = await self.state.start(monitor: self.monitor, queue: self.queue) { [weak self] path in
                verboseLog("[minimuxer] [net] path changed, status: \(path.status)")
                guard path.status == .satisfied else { return }
                self?.refreshEndpoint()
            }
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }
    
    func refreshEndpoint() {
        Task {
            await refreshEndpointAsync()
        }
    }

    private func refreshEndpointAsync() async {
        verboseLog("[minimuxer] [net] refreshing interfaces list and peers")
        await IfaceScanner.shared.refresh()

        verboseLog("[minimuxer] [net] retrive the first vpn interface info")
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
    func stop() -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var result = false
        Task { [weak self] in
            guard let self = self else {
                semaphore.signal()
                return
            }
            result = await self.state.stop(monitor: self.monitor)
            semaphore.signal()
        }
        semaphore.wait()
        return result
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
