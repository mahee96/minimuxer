//
//  MuxerService.swift
//  Minimuxer
//
//  Original Rust Implementation by @jkcoxson
//  Swift Port created by Magesh K on 02/03/26.
//

import Foundation

final internal class MuxerService {
    static private(set) var started = false
    static private(set) var isListening = false

    private static var deviceUDID: String?
    private static var serverThread: Thread?
    private static var listenSocket: Int32 = -1
    
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

    @discardableResult
    static func start(udid: String) async throws -> Bool {
        guard !started else {
            verboseLog("[minimuxer] Already started MuxerService, skipping")
            return false
        }
        deviceUDID = udid
        isListening = false
        
        let thread = Thread {
            listenLoop()
        }
        thread.name = "Muxer-Server"
        thread.qualityOfService = .userInitiated
        thread.start()
        
        serverThread = thread
        started = true

        let maxPolls = 10
        let pollIntervalNs: UInt64 = 100_000_000 // 100ms
        let totalTimeoutMs = 1000

        for _ in 0..<maxPolls {
            if isListening {
                verboseLog("[minimuxer] MuxerService is listening on socket!")
                return true
            }
            try? await Task.sleep(nanoseconds: pollIntervalNs)
        }
        
        debugLog("[minimuxer] MuxerService failed to bind/listen in time")
        let addr = "\(MinimuxerConstants.usbmuxdHost):\(MinimuxerConstants.usbmuxdPort)"
        let pollMs = pollIntervalNs / 1_000_000
        throw MinimuxerError.connect("MuxerService failed to listen on \(addr) within \(totalTimeoutMs)ms (\(maxPolls) × \(pollMs)ms polls)")
    }
    
    
    static func stop() {
        guard started else { return }
        serverThread?.cancel()

        started = false
        isListening = false
        deviceUDID = nil
        
        if listenSocket >= 0 {
            shutdown(listenSocket, SHUT_RDWR)
            close(listenSocket)
            listenSocket = -1
        }
        serverThread = nil
    }
    
    // MARK: - Listener

    // Binds a TCP server on 127.0.0.1:27015 and accepts incoming connections
    // from libimobiledevice/libusbmuxd. This is our fake usbmuxd — it speaks
    // just enough of the usbmuxd protocol for the library to discover the
    // device, read the pairing record, and open services (AFC, lockdown, etc.).
    private static func listenLoop() {
        while !Thread.current.isCancelled {
            logIfNeeded("MuxerService - Starting usbmuxd proxy server (listener loop)", isVerbose: true)

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
                isListening = false
                started = false
                Thread.sleep(forTimeInterval: 1)
                continue
            }

            verboseLog("[minimuxer] Bound successfully to \(MinimuxerConstants.usbmuxdHost):\(MinimuxerConstants.usbmuxdPort)")
            listenSocket = fd
            isListening = true
            started = true
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
            listenSocket = -1
            isListening = false
            started = false
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

    
    // MARK: - Packet Handling

    // Responds to the only usbmuxd protocol message("ListDevices") that
    // idevice requires to establish lockdown session when using lockdown based pairing file
    // (lockdown requires UDID to start session, so our server responds with data read from pair file)
    private static func handlePacket(_ packet: RawPacket, fd: Int32) throws -> [String: Any] {
        guard let messageType = packet.plist["MessageType"] as? String else {
            throw MinimuxerError.connect("Malformed usbmuxd packet: missing MessageType field")
        }
        
        verboseLog("[minimuxer] usbmux message: \(messageType)")
        
        switch messageType {
            case "ListDevices":
                guard let deviceIP = currentDeviceIP  else {
                    return ["DeviceList": []]
                }
                guard let udid = deviceUDID else {
                    throw MinimuxerError.pairingFile(protocol: .lockdown, reason: "No device UDID available for ListDevices response")
                }
                let networkAddr = convertIp(deviceIP)
                var payload: [String: Any] = [
                    "DeviceID": 0,                                                      // don't care
                    "Properties": [
                        "ConnectionType": "Network",                                    // using 'network' protocol of usbmuxd
                        "DeviceID": 0,                                                  // fake device id
                        "EscapedFullServiceName": "\(udid)._apple-mobdev2._tcp.local",  // advert for mds discovery
                        "InterfaceIndex": 0,                                            // don't care
                        "NetworkAddress": Data(networkAddr),                            // server host/interface address (ex: 10.7.0.1 ie remote)
                        "SerialNumber": udid                                            // device UDID
                    ]
                ]
                return ["DeviceList": [payload]]
            default:
                debugLog("[minimuxer] WARN: unknown message type: \(messageType)")
                throw MinimuxerError.connect("Unsupported usbmuxd message type: \(messageType)")
        }
    }
    
    private static let sockaddrInLength = UInt8(MemoryLayout<sockaddr_in>.size)
    private static let ipv4AddressFamily = UInt8(AF_INET)
    
    // Encodes an IPv4 address into the 152-byte sockaddr_storage layout that
    // libusbmuxd expects in the NetworkAddress field of the device properties.
    private static func convertIp(_ ip: String) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 152)
        var addr = in_addr()

        if inet_pton(AF_INET, ip, &addr) == 1 {
            data[0] = sockaddrInLength
            data[1] = ipv4AddressFamily

            let ipBytes = withUnsafeBytes(of: &addr.s_addr) { Array($0) }
            for (i, byte) in ipBytes.enumerated() {
                data[4 + i] = byte
            }
        }
        return data
    }
}
