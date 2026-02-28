import Foundation
import RustBridge

public class Install {
    public static func yeetAppAfc(bundleId: String, ipaBytes: Data) throws {
        print("[minimuxer] Yeeting IPA for bundle ID: \(bundleId)")
        let device = try Device.getFirstDevice()
        guard let afc = RustAfc.connect(device: device.internalInstance, label: "minimuxer") else {
            print("[minimuxer] ERROR: Could not start AFC service")
            throw MinimuxerError.CreateAfc
        }

        let pkg = MuxerConstants.pkgPath
        _ = afc.mkdir(path: "./\(pkg)")
        let appDir = "./\(pkg)/\(bundleId)"
        _ = afc.mkdir(path: appDir)

        if !afc.writeFile(path: "\(appDir)/app.ipa", data: ipaBytes) {
            print("[minimuxer] ERROR: Unable to write IPA to device")
            throw MinimuxerError.RwAfc
        }
        print("[minimuxer] Successfully staged IPA")
    }

    public static func installIpa(bundleId: String) throws {
        print("[minimuxer] Installing app for bundle ID: \(bundleId)")
        let device = try Device.getFirstDevice()
        guard let inst = RustInstProxy.connect(device: device.internalInstance, label: "ideviceinstaller") else {
            print("[minimuxer] ERROR: Unable to start instproxy")
            throw MinimuxerError.CreateInstproxy
        }
        let path = "./\(MuxerConstants.pkgPath)/\(bundleId)/app.ipa"
        print("[minimuxer] Installing...")
        if !inst.install(path: path) {
            print("[minimuxer] ERROR: Install failed")
            throw MinimuxerError.InstallApp("Failed to install")
        }
        print("[minimuxer] Install done!")
    }

    public static func removeApp(bundleId: String) throws {
        print("[minimuxer] Removing app: \(bundleId)")
        let device = try Device.getFirstDevice()
        guard let inst = RustInstProxy.connect(device: device.internalInstance, label: "minimuxer-remove-app") else {
            print("[minimuxer] ERROR: Unable to start instproxy")
            throw MinimuxerError.CreateInstproxy
        }
        print("[minimuxer] Removing...")
        if !inst.uninstall(bundleId: bundleId) {
            print("[minimuxer] ERROR: Unable to uninstall app")
            throw MinimuxerError.UninstallApp
        }
        print("[minimuxer] Remove done!")
    }
}
