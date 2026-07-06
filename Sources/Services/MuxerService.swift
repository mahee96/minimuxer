//
//  MuxerService.swift
//  Minimuxer
//
//  Original Rust Implementation by @jkcoxson
//  Swift Port created by Magesh K on 02/03/26.
//

import Foundation

final internal class MuxerService {
    static var started = false
    static var usbmuxdReady = false

    // Stable device state
    private static var currentDeviceIP: String?
    private static var currentEvent: String?

    static func notifyDeviceAttached(deviceIP: String){
        currentDeviceIP = deviceIP
        currentEvent = MinimuxerConstants.deviceAttach
    }
    static func notifyDeviceDetached(){
        currentDeviceIP = nil
        currentEvent = MinimuxerConstants.deviceDetach
    }

    private static var lastLogMessage: String?

    private static func logIfNeeded(_ message: String, isVerbose: Bool = false) {
        if message != lastLogMessage {
            if isVerbose {
                verboseLog("[minimuxer] \(message)")
            } else {
                debugLog("[minimuxer] \(message)")
            }
            lastLogMessage = message
        }
    }

    static func start() throws {
        if started {
            verboseLog("[minimuxer] Already started minimuxer, skipping")
            return
        }
        Thread.detachNewThread { listenLoop() }
        started = true
        verboseLog("[minimuxer] minimuxer has started!")
    }

    // MARK: - Listener

    // Binds a TCP server on 127.0.0.1:27015 and accepts incoming connections
    // from libimobiledevice/libusbmuxd. This is our fake usbmuxd — it speaks
    // just enough of the usbmuxd protocol for the library to discover the
    // device, read the pairing record, and open services (AFC, lockdown, etc.).
    private static func listenLoop() {
        while true {
            logIfNeeded("Starting listener", isVerbose: true)

            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else {
                Thread.sleep(forTimeInterval: 1)
                continue
            }

            var yes = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int>.size))
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = MinimuxerConstants.usbmuxdPort.bigEndian
            addr.sin_addr.s_addr = inet_addr(MinimuxerConstants.usbmuxdHost)

            let bindResult = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }

            let value = String(cString: getenv(MinimuxerConstants.usbmuxdEnvKey))
            logIfNeeded("muxer: (ENV) USBMUXD_SOCKET_ADDRESS = \(value)", isVerbose: true)

            guard bindResult == 0, listen(fd, 16) == 0 else {
                logIfNeeded("WARN: Failed to bind/listen")
                close(fd)
                usbmuxdReady = false
                Thread.sleep(forTimeInterval: 1)
                continue
            }

            verboseLog("[minimuxer] Bound successfully to \(MinimuxerConstants.usbmuxdHost):\(MinimuxerConstants.usbmuxdPort)")
            usbmuxdReady = true
            lastLogMessage = nil

            // accept loop — runs until socket dies
            var consecutiveErrors = 0
            while true {
                var clientAddr = sockaddr()
                var addrLen = socklen_t(MemoryLayout<sockaddr>.size)
                let clientFd = accept(fd, &clientAddr, &addrLen)
                guard clientFd >= 0 else {
                    consecutiveErrors += 1
                    debugLog("[minimuxer] WARN: accept() failed (\(consecutiveErrors)): \(String(cString: strerror(errno)))")
                    if consecutiveErrors > 0 {
                        debugLog("[minimuxer] ERROR: accept() repeatedly failing, restarting socket")
                        break  // break inner → outer loop recreates socket
                    }
                    Thread.sleep(forTimeInterval: 0.1)
                    continue
                }
                consecutiveErrors = 0

                var nosig = 1
                setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))

                Task.detached { handleClient(fd: clientFd) }
            }

            // socket died — close and let outer loop restart
            close(fd)
            usbmuxdReady = false
            logIfNeeded("[minimuxer] listener restarting...", isVerbose: true)
            Thread.sleep(forTimeInterval: 1)
        }
    }
    
    private static func handleClient(fd: Int32) {
        var shouldCloseFd = true
        defer {
            if shouldCloseFd {
                close(fd)
            }
        }

        let bufLen = 0xfff
        var buffer = [UInt8](repeating: 0, count: bufLen)

        while true {
            let bytesRead = recv(fd, &buffer, bufLen, 0)
            guard bytesRead > 0 else { return }
            var totalRead = bytesRead

            // libimobiledevice sometimes sends the 16-byte packet header in
            // one write and the plist body in a follow-up write. If we only
            // got the header, block for the body before trying to parse.
            if bytesRead == 16 {
                let extra = recv(fd, &buffer[16], bufLen - 16, 0)
                if extra > 0 { totalRead += extra }
            }

            let data = Data(buffer[0..<totalRead])
            guard let packet = RawPacket(data: data) else { return }

            do {
                let response = try handlePacket(packet, fd: fd)
                let responsePacket = RawPacket(plist: response, version: 1, message: 8, tag: packet.tag)
                let responseData = responsePacket.data
                responseData.withUnsafeBytes { ptr in
                    _ = send(fd, ptr.baseAddress!, responseData.count, 0)
                }
            } catch {}
        }
    }

    
    private static func buildPayload(deviceIP: String, event: String? = nil) throws -> [String: Any] {
        guard let udid = Minimuxer.shared.getPairingInfo()?.dictionary["UDID"] as? String else {
            throw MinimuxerError.PairingFile
        }

        let networkAddr = convertIp(deviceIP)

        var payload: [String: Any] = [
            "DeviceID": 420,
            "Properties": [
                "ConnectionType": "Network",
                "DeviceID": 420,
                "EscapedFullServiceName": "\(udid)._apple-mobdev2._tcp.local",
                "InterfaceIndex": 69,
                "NetworkAddress": Data(networkAddr),
                "SerialNumber": udid
            ]
        ]

        if let event = event {
            payload["MessageType"] = event
        }

        return payload
    }
    
    // MARK: - Packet Handling

    // Responds to the subset of usbmuxd protocol messages that
    // libimobiledevice actually needs from us:
    private static func handlePacket(_ packet: RawPacket, fd: Int32) throws -> [String: Any] {
        guard let messageType = packet.plist["MessageType"] as? String else {
            throw MinimuxerError.Connect
        }

        verboseLog("[minimuxer] usbmux message: \(messageType)")

        switch messageType {
            case "ListDevices":
                guard let deviceIP = currentDeviceIP,
                      let payload = try? buildPayload(deviceIP: deviceIP) else {
                    return ["DeviceList": []]
                }
                return ["DeviceList": [payload]]
                
            case "Listen":
                if let deviceIP = currentDeviceIP {
                     Task.detached {
                         if let payload = try? buildPayload(deviceIP: deviceIP, event: currentEvent) {
                             let pkt = RawPacket(plist: payload, version: 1, message: 8, tag: 0)
                             let data = pkt.data
                             data.withUnsafeBytes { _ = send(fd, $0.baseAddress!, data.count, 0) }
                         }
                     }
                }
                return ["MessageType": "Result", "Number": 0]
                
            case "ReadBUID":
                let dummyBUID = "00000000-0000-0000-0000-000000000000"
                let buid = Minimuxer.shared.getPairingInfo()?.dictionary["SystemBUID"] as? String ?? dummyBUID
                return ["BUID": buid]

            case "ReadPairRecord":
                let pairingData = Minimuxer.shared.getPairingInfo()?.xmlData ?? Data()
                return [
                    "MessageType": "Result",
                    "Number": 0,
                    "PairRecordData": pairingData
                ]

            default:
                debugLog("[minimuxer] WARN: unknown message type: \(messageType)")
                throw MinimuxerError.Connect
        }
    }


    private static func emitDeviceEvent(fd: Int32, type: String, payload: [String: Any]) {
        let plist: [String: Any] = [
            "MessageType": type,
            "DeviceID": payload["DeviceID"]!
        ]

        let pkt = RawPacket(plist: plist, version: 1, message: 8, tag: 0)
        let data = pkt.data
        data.withUnsafeBytes {
            _ = send(fd, $0.baseAddress!, data.count, 0)
        }
    }
    

    // MARK: - Helpers

    // Encodes an IPv4 address into the 152-byte sockaddr_storage layout that
    // libusbmuxd expects in the NetworkAddress field of the device properties.
    private static func convertIp(_ ip: String) -> [UInt8] {
        // verboseLog("[minimuxer] DEBUG: convertIp called for ip: \(ip)")
        var data = [UInt8](repeating: 0, count: 152)
        var addr = in_addr()
        if inet_pton(AF_INET, ip, &addr) == 1 {
//             data[0] = 10; data[1] = 0x02
            data[0] = 16; data[1] = 0x02
            let ipBytes = withUnsafeBytes(of: &addr.s_addr) { Array($0) }
            for (i, byte) in ipBytes.enumerated() { data[4 + i] = byte }
            // verboseLog("[minimuxer] DEBUG: convertIp output bytes 0..7: \(data[0...7])")
        }
        return data
    }
}
