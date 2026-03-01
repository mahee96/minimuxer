import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public class Muxer {
    public static var started = false
    public static var usbmuxdReady = true
    
    public static func targetMinimuxerAddress() {
        print("[minimuxer] setenv(USBMUXD_SOCKET_ADDRESS, \(MuxerConstants.usbmuxdSocket))")
        
        setenv(MuxerConstants.usbmuxdEnvKey, MuxerConstants.usbmuxdSocket, 1)
        
        let value = String(cString: getenv(MuxerConstants.usbmuxdEnvKey))
        print("[minimuxer] getenv(USBMUXD_SOCKET_ADDRESS) =", value)
    }
    
    public static func start(pairingFile: String, logPath: String, ifaddr: String?) throws {
        if started {
            print("[minimuxer] Already started minimuxer, skipping")
            return
        }

        let loggerPath = logPath.hasPrefix("file://") ? String(logPath.dropFirst(7)) : logPath
        let fullLogPath = "\(loggerPath)/minimuxer.log"
        try? FileManager.default.removeItem(atPath: fullLogPath)

        guard let pairingData = pairingFile.data(using: .utf8),
              let pairingDict = try? PropertyListSerialization.propertyList(from: pairingData, options: [], format: nil) as? [String: Any] else {
            print("[minimuxer] ERROR: Failed to parse pairing file")
            throw MinimuxerError.PairingFile
        }
        guard let _ = pairingDict["UDID"] as? String else {
            print("[minimuxer] ERROR: Pairing file missing UDID")
            throw MinimuxerError.PairingFile
        }

        started = true
        Thread.detachNewThread { listenLoop(pairingDict: pairingDict, ifaddr: ifaddr) }
        Heartbeat.startBeat()
        print("[minimuxer] minimuxer has started!")
    }

    private static func listenLoop(pairingDict: [String: Any], ifaddr: String?) {
        print("[minimuxer] Starting listener")
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = MuxerConstants.usbmuxdPort.bigEndian
        addr.sin_addr.s_addr = inet_addr(MuxerConstants.usbmuxdHost)

        var yes = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int>.size))

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        
        let value = String(cString: getenv(MuxerConstants.usbmuxdEnvKey))
        print("[minimuxer] muxer: (ENV) USBMUXD_SOCKET_ADDRESS =", value)
        
        guard bindResult == 0, listen(fd, 5) == 0 else {
            print("[minimuxer] WARN: Failed to bind/listen, will retry")
            return
        }
        print("[minimuxer] Bound successfully to \(MuxerConstants.usbmuxdHost):\(MuxerConstants.usbmuxdPort)")
        Muxer.usbmuxdReady = true

        while true {
            var clientAddr = sockaddr()
            var addrLen = socklen_t(MemoryLayout<sockaddr>.size)
            let clientFd = accept(fd, &clientAddr, &addrLen)
            guard clientFd >= 0 else { continue }
            var addr = sockaddr_in()

            /*
             DEBUG: Uncomment below code to log each incoming usbmux client TCP connection.
                    usbmuxd/libimobiledevice opens many short-lived connections,
                    each using a new ephemeral source port — this is expected
                    and helps diagnose connection churn or handshake loops.
             */
//            memcpy(&addr, &clientAddr, MemoryLayout<sockaddr_in>.size)
//            let ip = String(cString: inet_ntoa(addr.sin_addr))
//            let port = UInt16(bigEndian: addr.sin_port)
//            print("[minimuxer] client connected from \(ip):\(port) (fd=\(clientFd))")

            handleClient(fd: clientFd, pairingDict: pairingDict, ifaddr: ifaddr)
        }
    }

    private static func handleClient(fd: Int32, pairingDict: [String: Any], ifaddr: String?) {
        let bufLen = 0xfff
        var buffer = [UInt8](repeating: 0, count: bufLen)
        
        defer { close(fd) }

        // client is active, so keep responding to the socket
        let bytesRead = recv(fd, &buffer, bufLen, 0)
        guard bytesRead > 0 else { return }

        let data = Data(buffer[0..<bytesRead])
        guard let packet = RawPacket(data: data) else { return }

        do {
            let response = try handlePacket(packet, pairingDict: pairingDict, ifaddr: ifaddr)
            let responsePacket = RawPacket(plist: response, version: 1, message: 8, tag: packet.tag)
            let responseData = responsePacket.data
            responseData.withUnsafeBytes { ptr in
                _ = send(fd, ptr.baseAddress!, responseData.count, 0)
            }
        } catch {}
    }

    private static func handlePacket(_ packet: RawPacket, pairingDict: [String: Any], ifaddr: String?) throws -> [String: Any] {
        guard let messageType = packet.plist["MessageType"] as? String else {
            throw MinimuxerError.NoConnection
        }

        switch messageType {
        case "ListDevices":
            guard let udid = pairingDict["UDID"] as? String else { throw MinimuxerError.PairingFile }
            let ip = ifaddr ?? MuxerConstants.deviceIP
            let networkAddr = convertIp(ip)
            let properties: [String: Any] = [
                "ConnectionType": "Network",
                "DeviceID": 420,
                "EscapedFullServiceName": "\(udid)._apple-mobdev2._tcp.local",
                "InterfaceIndex": 69,
                "NetworkAddress": Data(networkAddr),
                "SerialNumber": udid
            ]
            return ["DeviceList": [["DeviceID": 420, "MessageType": "Attached", "Properties": properties]]]

        case "Listen":
            print("[minimuxer] usbmux client registered (Listen received)")
            return ["Result": 0]

        case "ReadPairRecord":
            let data = try PropertyListSerialization.data(fromPropertyList: pairingDict, format: .xml, options: 0)
            return ["PairRecordData": data]

        default:
            throw MinimuxerError.NoConnection
        }
    }

    private static func convertIp(_ ip: String) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 152)
        var addr = in_addr()
        if inet_pton(AF_INET, ip, &addr) == 1 {
            data[0] = 10; data[1] = 0x02
            let ipBytes = withUnsafeBytes(of: &addr.s_addr) { Array($0) }
            for (i, byte) in ipBytes.enumerated() { data[4 + i] = byte }
        }
        return data
    }
}
