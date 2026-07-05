//
//  MounterService.swift
//  Minimuxer
//
//  Original Rust Implementation by @jkcoxson
//  Swift Port created by Magesh K on 02/03/26.
//

import Foundation
// import RustBridge
import ZIPFoundation

internal protocol MounterServiceProvider: AnyObject {
    var dmgMounted:Bool { get set }
    func isReady() -> Bool
    func startAutoMounter(docsPath: String) async;
}

final internal class MounterService {
    static var provider: MounterServiceProvider?;

    private static func getProvider() -> any MounterServiceProvider {
        if let provider {
            return provider
        } else {
            if Minimuxer.shared.isrppairing {
                provider = RPMounterService()
            } else {
                provider = LockDownMounterService()
            }
        }
        return provider!
    }
    static func startAutoMounter(docsPath: String) async {
        await getProvider().startAutoMounter(docsPath: docsPath)
    }

    static func isReady() -> Bool {
        getProvider().isReady()
    }

    static var dmgMounted: Bool {
        get { getProvider().dmgMounted }
        set { getProvider().dmgMounted = newValue }
    }
}

final internal class LockDownMounterService: MounterServiceProvider {
    var dmgMounted = false
    private var lastErrorDescription: String? = nil {
        didSet {
            if lastErrorDescription != oldValue {
                hasPrintedCurrentError = false
            }
        }
    }
    private var hasPrintedCurrentError = false
    private let state = MutableState()

    func isReady() -> Bool {
        if dmgMounted {
            hasPrintedCurrentError = false
            return true
        }
        if let error = lastErrorDescription, !hasPrintedCurrentError {
            debugLog("[minimuxer] Last mounter error: \(error)")
            hasPrintedCurrentError = true
        }
        return false
    }

    func startAutoMounter(docsPath: String) async {
        guard await state.tryStart() else {
            return
        }

        let path = docsPath.hasPrefix("file://") ? String(docsPath.dropFirst(7)) : docsPath
        let dmgDocsPath = "\(path)/DMG"

        verboseLog("[minimuxer] mount-task: Starting mount task...")
        Task.detached { [weak self] in
            guard let self = self else { return }
            verboseLog("[minimuxer] mount-task: started")
            
            await self.mountLoop(dmgDocsPath: dmgDocsPath)
            
            await self.state.stop()
            verboseLog("[minimuxer] mount-task: stopped")
        }
    }

    private func logIfNeeded(_ message: String, prefix: String, isVerbose: Bool = false) {
        if message != lastErrorDescription {
            if isVerbose {
                verboseLog("[minimuxer] \(prefix)\(message)")
            } else {
                debugLog("[minimuxer] \(prefix)\(message)")
            }
            lastErrorDescription = message
        }
    }

    private func mountLoop(dmgDocsPath: String) async {
        while !MuxerService.usbmuxdReady {
            logIfNeeded("Waiting for usbmuxd to be ready...", prefix: "mount-task: ", isVerbose: true)
            try? await Task.sleep(nanoseconds: MinimuxerConstants.mounterSleepNs)
        }
        verboseLog("[minimuxer] mount-task: usbmuxd is ready")

        try? FileManager.default.createDirectory(atPath: dmgDocsPath, withIntermediateDirectories: true)

        while !self.dmgMounted {
            try? await Task.sleep(nanoseconds: MinimuxerConstants.mounterSleepNs)
            do {
                guard let versionStr = try IdeviceGateway.shared.getLockdownValue(key: "ProductVersion") else {
                    logIfNeeded("Could not get device version for mounter", prefix: "mount-task: WARN: ")
                    continue
                }

                let major = Int(versionStr.split(separator: ".").first ?? "0") ?? 0
                if major < 17 {
                    try await self.handlePre17Mount(iosVersion: versionStr, dmgDocsPath: dmgDocsPath)
                } else {
                    try await self.handlePost17Mount(dmgDocsPath: dmgDocsPath)
                }
                self.lastErrorDescription = nil
            } catch let error as MinimuxerError {
                if error == .NoDevice {
                    continue
                }
                logIfNeeded("\(error)", prefix: "mount-task: ERROR: Mount failed with .NoDevice error: ")
                await Minimuxer.shared.checkAndNotify(.failed(.mounter, error))
                return
            } catch let error as IdeviceGatewayError {
                switch error {
                case .connectionFailed, .noConnection:
                    // Keep retrying if the device is not yet present on usbmuxd or connection is pending
                    continue
                default:
                    logIfNeeded("\(error)", prefix: "mount-task: ERROR: Mount failed with gateway error: ")
                    await Minimuxer.shared.checkAndNotify(.failed(.mounter, error))
                    return
                }
            } catch {
                logIfNeeded("\(error)", prefix: "mount-task: ERROR: Mount failed with unknown error: ")
                await Minimuxer.shared.checkAndNotify(.failed(.mounter, error))
                return
            }
        }
    }

    private func handlePre17Mount(iosVersion: String, dmgDocsPath: String) async throws {
        verboseLog("[minimuxer] Starting image mounter (pre-17)")
        
        let dmgPath = "\(dmgDocsPath)/\(iosVersion).dmg"
        let sigPath = "\(dmgPath).signature"
        
        verboseLog("[minimuxer] Pre17 DMG: \(dmgPath)")
        verboseLog("[minimuxer] Pre17 Signature: \(sigPath)")
        
        if !FileManager.default.fileExists(atPath: dmgPath) {
            verboseLog("[minimuxer] Downloading iOS \(iosVersion) DMG...")
            try LockDownMounterService.downloadPre17Image(iosVersion: iosVersion, dmgDocsPath: dmgDocsPath)
        }

        guard let dmgData = try? Data(contentsOf: URL(fileURLWithPath: dmgPath)),
              let sigData = try? Data(contentsOf: URL(fileURLWithPath: sigPath)) else {
            debugLog("[minimuxer] ERROR: Unable to read developer disk image or signature files")
            throw MinimuxerError.Mount
        }

        verboseLog("[minimuxer] Uploading and mounting image (dmg=\(dmgData.count) bytes, sig=\(sigData.count) bytes)...")
        do {
            try IdeviceGateway.shared.mountDeveloperImage(image: dmgData, signature: sigData)
            verboseLog("[minimuxer] Successfully mounted the image")
            dmgMounted = true
            await Minimuxer.shared.checkAndNotify(.ready(.mounter))
        } catch {
            debugLog("[minimuxer] ERROR: Unable to mount developer image: \(error)")
            throw MinimuxerError.Mount
        }
    }

    private func handlePost17Mount(dmgDocsPath: String) async throws {
        let (imageData, trustcacheData, manifestData) = try LockDownMounterService.loadPost17Image(dmgDocsPath: dmgDocsPath)

        verboseLog(
            "[minimuxer] Mounting DDI " +
            "(image=\(imageData.count) bytes, " +
            "trustcache=\(trustcacheData.count) bytes, " +
            "manifest=\(manifestData.count) bytes)"
        )

        try IdeviceGateway.shared.mountPersonalizedDdi(image: imageData, trustcache: trustcacheData, manifest: manifestData)
        verboseLog("[minimuxer] DDI mounted successfully")
        dmgMounted = true
        await Minimuxer.shared.checkAndNotify(.ready(.mounter))
    }

    static func loadPost17Image(dmgDocsPath: String) throws -> (Data, Data, Data){
        let dir = URL(fileURLWithPath: dmgDocsPath)
        let tasks: [(String, URL)] = [
            (MinimuxerConstants.ddiImageURL, dir.appendingPathComponent("Image.dmg")),
            (MinimuxerConstants.ddiTrustcacheURL, dir.appendingPathComponent("Image.dmg.trustcache")),
            (MinimuxerConstants.ddiManifestURL, dir.appendingPathComponent("BuildManifest.plist"))
        ]

        for (urlStr, path) in tasks {
            if !FileManager.default.fileExists(atPath: path.path) {
                verboseLog("[minimuxer] Downloading \(path.lastPathComponent)...")
                guard let url = URL(string: urlStr), let data = try? Data(contentsOf: url) else {
                    debugLog("[minimuxer] ERROR: Failed to download \(path.lastPathComponent)")
                    throw MinimuxerError.DownloadImage
                }
                try data.write(to: path)
            }
        }
        verboseLog("[minimuxer] Files downloaded, reading to memory")

         let imageURL = tasks[0].1
         let trustcacheURL = tasks[1].1
         let manifestURL = tasks[2].1

         verboseLog("[minimuxer] Image:      \(imageURL.path)")
         verboseLog("[minimuxer] Trustcache: \(trustcacheURL.path)")
         verboseLog("[minimuxer] Manifest:   \(manifestURL.path)")

         let imageData = try Data(contentsOf: imageURL)
         let trustcacheData = try Data(contentsOf: trustcacheURL)
         let manifestData = try Data(contentsOf: manifestURL)


        return (imageData, trustcacheData, manifestData)
    }

    private static func downloadPre17Image(iosVersion: String, dmgDocsPath: String) throws {
        guard let url = URL(string: MinimuxerConstants.pre17VersionsURL),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let dmgUrlStr = json[iosVersion],
              let dmgUrl = URL(string: dmgUrlStr) else {
            debugLog("[minimuxer] ERROR: Unable to download DMG dictionary or find version")
            throw MinimuxerError.DownloadImage
        }

        let zipData = try Data(contentsOf: dmgUrl)
        let zipPath = "\(dmgDocsPath)/dmg.zip"
        try zipData.write(to: URL(fileURLWithPath: zipPath))

        let tmpPath = "\(dmgDocsPath)/tmp"
        try? FileManager.default.removeItem(atPath: tmpPath)
        try FileManager.default.createDirectory(atPath: tmpPath, withIntermediateDirectories: true)

        let tmpPathURL = URL(fileURLWithPath: tmpPath)
        try FileManager.default.unzipItem(at: URL(fileURLWithPath: zipPath), to: tmpPathURL)
        try? FileManager.default.removeItem(atPath: zipPath)

        for item in try FileManager.default.contentsOfDirectory(atPath: tmpPath) {
            let itemPath = "\(tmpPath)/\(item)"
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: itemPath, isDirectory: &isDir), isDir.boolValue,
                  !item.contains("__MACOSX") else { continue }
            let dmgFile = "\(itemPath)/DeveloperDiskImage.dmg"
            let sigFile = "\(itemPath)/DeveloperDiskImage.dmg.signature"
            if FileManager.default.fileExists(atPath: dmgFile) {
                try FileManager.default.moveItem(atPath: dmgFile, toPath: "\(dmgDocsPath)/\(iosVersion).dmg")
                try FileManager.default.moveItem(atPath: sigFile, toPath: "\(dmgDocsPath)/\(iosVersion).dmg.signature")
            }
        }
        try? FileManager.default.removeItem(atPath: tmpPath)
    }
}

final internal class RPMounterService: MounterServiceProvider {
    var dmgMounted: Bool = false
    private var lastErrorDescription: String? = nil {
        didSet {
            if lastErrorDescription != oldValue {
                hasPrintedCurrentError = false
            }
        }
    }
    private var hasPrintedCurrentError = false
    private let state = MutableState()

    func isReady() -> Bool {
        if dmgMounted {
            hasPrintedCurrentError = false
            return true
        }
        if let error = lastErrorDescription, !hasPrintedCurrentError {
            debugLog("[minimuxer] Last mounter error: \(error)")
            hasPrintedCurrentError = true
        }
        return false
    }

    func startAutoMounter(docsPath: String) async {
        guard !dmgMounted, await state.tryStart() else {
            return
        }

        let path = docsPath.hasPrefix("file://") ? String(docsPath.dropFirst(7)) : docsPath
        let dmgDocsPath = (path.hasSuffix("/") ? String(path.dropLast()) : path) + "/DMG"

        verboseLog("[minimuxer] mount-task: Starting mount task...")
        Task.detached { [weak self] in
            guard let self = self else { return }
            verboseLog("[minimuxer] mount-task: started")
            
            await self.mountLoop(dmgDocsPath: dmgDocsPath)
            
            await self.state.stop()
            verboseLog("[minimuxer] mount-task: stopped")
        }
    }

    private func logIfNeeded(_ message: String, prefix: String = "ERROR: Failed to mount DDI: ", isVerbose: Bool = false) {
        if message != lastErrorDescription {
            if isVerbose {
                verboseLog("[minimuxer] \(prefix)\(message)")
            } else {
                debugLog("[minimuxer] \(prefix)\(message)")
            }
            lastErrorDescription = message
        }
    }

    private func mountLoop(dmgDocsPath: String) async {
        do {
            try FileManager.default.createDirectory(atPath: dmgDocsPath, withIntermediateDirectories: true)
            let (imageData, trustcacheData, manifestData) = try LockDownMounterService.loadPost17Image(dmgDocsPath: dmgDocsPath)

            while !self.dmgMounted {
                try? await Task.sleep(nanoseconds: MinimuxerConstants.mounterSleepNs)
                guard (try? await DeviceEndpoint.shared.ip()) != nil else {
                    continue
                }
                do {
                    try IdeviceGateway.shared.mountPersonalizedDdi(image: imageData, trustcache: trustcacheData, manifest: manifestData)
                    verboseLog("[minimuxer] DDI mounted successfully")
                    self.dmgMounted = true
                    self.lastErrorDescription = nil
                } catch {
                    let errStr = "\(error)"
                    logIfNeeded(errStr, isVerbose: true)

                    if (error as? MinimuxerError) == .PairingFile || errStr.contains("PairVerifyFailed") || errStr.contains("Connection reset by peer") || errStr.contains("ConnectionReset") {
                        debugLog("[minimuxer] mounter-task: ERROR: Invalid pairing file — the device rejected the remote pairing handshake. Please redo-pairing for your device.")
                        debugLog("[minimuxer] mounter-task: exiting due to invalid pairing")
                        await Minimuxer.shared.checkAndNotify(.failed(.mounter, MinimuxerError.PairingFile))
                        return
                    }
                }
            }
        } catch {
            debugLog("[minimuxer] ERROR: \(error)")
        }
    }
}



private actor MutableState {
    private var taskActive = false
    
    func tryStart() -> Bool {
        if taskActive {
            return false
        }
        taskActive = true
        return true
    }
    
    func stop() {
        taskActive = false
    }
}
