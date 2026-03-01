import Foundation
import RustBridge

public class Heartbeat {
    public static var lastBeatSuccessful = false

    public static func startBeat() {
        Thread.detachNewThread {
            print("[minimuxer] Starting heartbeat thread...")
            while !Muxer.ready {
                print("[minimuxer] mounter-thread: Waiting for usbmuxd to be ready...")
                Thread.sleep(forTimeInterval: 0.1)
            }
            print("[minimuxer] heartbeat-thread: usbmuxd is ready")

            while true {
                let device: Device
                do {
                    device = try Device.getFirstDevice()
                } catch {
                    print("[minimuxer] WARN: Could not get device from muxer for heartbeat")
                    lastBeatSuccessful = false
                    Thread.sleep(forTimeInterval: 0.1)
                    continue
                }

                guard let heartbeat = RustHeartbeat.connect(device: device.internalInstance, label: "minimuxer") else {
                    print("[minimuxer] ERROR: Failed to create heartbeat client")
                    lastBeatSuccessful = false
                    Thread.sleep(forTimeInterval: 0.1)
                    continue
                }

                // Inner loop: keep receiving and sending heartbeats
                while true {
                   guard let plist = heartbeat.receive(timeoutMs: MuxerConstants.heartbeatTimeoutMs) else {
                       print("[minimuxer] ERROR: Heartbeat recv failed")
                       lastBeatSuccessful = false
                       break
                   }

                    if heartbeat.send(plistXml: plist) {
                        lastBeatSuccessful = true
                    } else {
                        print("[minimuxer] ERROR: Heartbeat send failed")
                        lastBeatSuccessful = false
                        break
                    }
                }
            }
        }
    }
}
