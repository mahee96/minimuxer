//
//  MounterService.swift
//  Minimuxer
//
//  Original Rust Implementation by @jkcoxson
//  Swift Port created by Magesh K on 02/03/26.
//

import Foundation
import ZIPFoundation

final internal class MounterService {


    private static let shared = MounterService()


    static var isReady: Bool        { shared._isReady }
    static var dmgMounted: Bool     { shared._dmgMounted }

    static func startAutoMounter(docsPath: String) async {
        await shared._startAutoMounter(docsPath: docsPath)
    }

    static func restart() async {
        await shared._restart()
    }


    private actor MutableState {
        private var taskActive = false
        private(set) var mountTask: Task<Void, any Error>? = nil

        func tryStart() -> Bool {
            guard !taskActive else { return false }
            taskActive = true
            return true
        }

        func stop() {
            taskActive = false
        }

        func setCurrentMountTask(task: Task<Void, any Error>) {
            mountTask = task
        }
    }

    private var _dmgMounted = false
    private var lastErrorDescription: String? = nil {
        didSet {
            if lastErrorDescription != oldValue {
                hasPrintedCurrentError = false
            }
        }
    }
    private var hasPrintedCurrentError = false
    private let state = MutableState()

    private var isRPPairing: Bool { IdeviceGateway.shared.isRPPairing }


    private var _isReady: Bool {
        if _dmgMounted {
            hasPrintedCurrentError = false
            return true
        }
        if let error = lastErrorDescription, !hasPrintedCurrentError {
            debugLog("[minimuxer] Last mounter error: \(error)")
            hasPrintedCurrentError = true
        }
        return false
    }


    private func _restart() async {
        _dmgMounted = false
    }


    private func _startAutoMounter(docsPath: String) async {
        guard !_dmgMounted, await state.tryStart() else { return }

        let path = docsPath.hasPrefix("file://") ? String(docsPath.dropFirst(7)) : docsPath
        let dmgDocsPath = (path.hasSuffix("/") ? String(path.dropLast()) : path) + "/DMG"

        verboseLog("[minimuxer] mount-task: Starting mount task...")
        let task = Task.detached { [weak self] in
            guard let self = self else { return }
            verboseLog("[minimuxer] mount-task: started")

            do {
                try await self.mountLoop(dmgDocsPath: dmgDocsPath)
            } catch {
                debugLog("[minimuxer] mount-task: exited with error: \(error)")
            }

            await self.state.stop()
            verboseLog("[minimuxer] mount-task: stopped")
        }
        await state.setCurrentMountTask(task: task)
    }


    private func logIfNeeded(_ message: String, prefix: String = "", isVerbose: Bool = false) {
        if message != lastErrorDescription {
            if isVerbose {
                verboseLog("[minimuxer] \(prefix)\(message)")
            } else {
                debugLog("[minimuxer] \(prefix)\(message)")
            }
            lastErrorDescription = message
        }
    }


    private func mountLoop(dmgDocsPath: String) async throws {
        // Lockdown path requires our fake usbmuxd to be up first.
        // RP pairing (RSD) connects directly — no muxer needed.
        if !isRPPairing {
            while !MuxerService.isReady {
                logIfNeeded("Waiting for usbmuxd to be ready...", prefix: "mount-task: ", isVerbose: true)
                try? await Task.sleep(nanoseconds: MinimuxerConstants.mounterSleepNs)
            }
            verboseLog("[minimuxer] mount-task: usbmuxd is ready")
        }

        try? FileManager.default.createDirectory(atPath: dmgDocsPath, withIntermediateDirectories: true)

        while !_dmgMounted {
            // Wait for a device IP before attempting any mount call
            guard (try? await DeviceEndpoint.shared.ip()) != nil else {
                logIfNeeded("Waiting for deviceIP to be ready...", prefix: "mount-task: ", isVerbose: true)
                try? await Task.sleep(nanoseconds: MinimuxerConstants.mounterSleepNs)
                continue
            }

            if isRPPairing {
                // RP pairing: always post-17, connects via RSD — no lockdown version lookup needed
                try await mountRPPath(dmgDocsPath: dmgDocsPath)
            } else {
                // Lockdown path: get device version, dispatch pre-17 vs post-17
                try await mountLockdownPath(dmgDocsPath: dmgDocsPath)
            }
        }
    }


    private func mountRPPath(dmgDocsPath: String) async throws {
        do {
            try await handlePost17Mount(dmgDocsPath: dmgDocsPath)
            lastErrorDescription = nil
        } catch {
            let errStr = "\(error)"
            logIfNeeded(errStr, prefix: "mount-task: ERROR: Mount failed: ", isVerbose: true)

            if isPairingError(error, errStr) {
                debugLog("[minimuxer] mounter-task: ERROR: Invalid pairing file — the device rejected the remote pairing handshake. Please redo-pairing for your device.")
                debugLog("[minimuxer] mounter-task: exiting due to invalid pairing")
                await Minimuxer.shared.checkAndNotify(.failed(.mounter, MinimuxerError.PairingFile))
                throw MinimuxerError.PairingFile
            }
            // Non-fatal: keep retrying on next loop iteration
            try? await Task.sleep(nanoseconds: MinimuxerConstants.mounterSleepNs)
        }
    }


    private func mountLockdownPath(dmgDocsPath: String) async throws {
        guard let versionStr = try? IdeviceGateway.shared.getLockdownValue(key: "ProductVersion") else {
            logIfNeeded("Could not get device version for mounter", prefix: "mount-task: WARN: ", isVerbose: true)
            try? await Task.sleep(nanoseconds: MinimuxerConstants.mounterSleepNs)
            return  // non-fatal, outer loop retries
        }

        let major = Int(versionStr.split(separator: ".").first ?? "0") ?? 0

        do {
            if major < 17 {
                try await handlePre17Mount(iosVersion: versionStr, dmgDocsPath: dmgDocsPath)
            } else {
                try await handlePost17Mount(dmgDocsPath: dmgDocsPath)
            }
            lastErrorDescription = nil
        } catch let error as MinimuxerError {
            if error == .NoDevice {
                return  // non-fatal, retry
            }
            logIfNeeded("\(error)", prefix: "mount-task: ERROR: Mount failed: ")
            await Minimuxer.shared.checkAndNotify(.failed(.mounter, error))
            throw error
        } catch let error as IdeviceGatewayError {
            switch error {
            case .connectionFailed, .noConnection:
                // Device not yet visible on usbmuxd — keep retrying
                return
            default:
                logIfNeeded("\(error)", prefix: "mount-task: ERROR: Mount failed with gateway error: ")
                await Minimuxer.shared.checkAndNotify(.failed(.mounter, error))
                throw error
            }
        } catch {
            let errStr = "\(error)"
            if isPairingError(error, errStr) {
                debugLog("[minimuxer] mounter-task: ERROR: Invalid pairing file — the device rejected the remote pairing handshake. Please redo-pairing for your device.")
                debugLog("[minimuxer] mounter-task: exiting due to invalid pairing")
                await Minimuxer.shared.checkAndNotify(.failed(.mounter, MinimuxerError.PairingFile))
                throw MinimuxerError.PairingFile
            }
            logIfNeeded(errStr, prefix: "mount-task: ERROR: Mount failed with unknown error: ")
            await Minimuxer.shared.checkAndNotify(.failed(.mounter, error))
            throw error
        }
    }


    private func isPairingError(_ error: Error, _ errStr: String) -> Bool {
        return (error as? MinimuxerError) == .PairingFile
            || errStr.contains("PairVerifyFailed")
            || errStr.contains("Connection reset by peer")
            || errStr.contains("ConnectionReset")
    }


    private func handlePre17Mount(iosVersion: String, dmgDocsPath: String) async throws {
        verboseLog("[minimuxer] Starting image mounter (pre-17)")

        let dmgPath = "\(dmgDocsPath)/\(iosVersion).dmg"
        let sigPath = "\(dmgPath).signature"

        verboseLog("[minimuxer] Pre17 DMG: \(dmgPath)")
        verboseLog("[minimuxer] Pre17 Signature: \(sigPath)")

        if !FileManager.default.fileExists(atPath: dmgPath) {
            verboseLog("[minimuxer] Downloading iOS \(iosVersion) DMG...")
            try MounterService.downloadPre17Image(iosVersion: iosVersion, dmgDocsPath: dmgDocsPath)
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
            _dmgMounted = true
            await Minimuxer.shared.checkAndNotify(.ready(.mounter))
        } catch {
            debugLog("[minimuxer] ERROR: Unable to mount developer image: \(error)")
            throw MinimuxerError.Mount
        }
    }


    private func handlePost17Mount(dmgDocsPath: String) async throws {
        let (imageData, trustcacheData, manifestData) = try MounterService.loadPost17Image(dmgDocsPath: dmgDocsPath)

        debugLog(
            "[minimuxer] Mounting DDI " +
            "(image=\(imageData.count) bytes, " +
            "trustcache=\(trustcacheData.count) bytes, " +
            "manifest=\(manifestData.count) bytes)"
        )

        try IdeviceGateway.shared.mountPersonalizedDdi(image: imageData, trustcache: trustcacheData, manifest: manifestData)
        verboseLog("[minimuxer] DDI mounted successfully")
        _dmgMounted = true
        await Minimuxer.shared.checkAndNotify(.ready(.mounter))
    }


    static func loadPost17Image(dmgDocsPath: String) throws -> (Data, Data, Data) {
        let dir = URL(fileURLWithPath: dmgDocsPath)
        let tasks: [(String, URL)] = [
            (MinimuxerConstants.ddiImageURL,      dir.appendingPathComponent("Image.dmg")),
            (MinimuxerConstants.ddiTrustcacheURL, dir.appendingPathComponent("Image.dmg.trustcache")),
            (MinimuxerConstants.ddiManifestURL,   dir.appendingPathComponent("BuildManifest.plist"))
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

        let imageURL      = tasks[0].1
        let trustcacheURL = tasks[1].1
        let manifestURL   = tasks[2].1

        verboseLog("[minimuxer] Image:      \(imageURL.path)")
        verboseLog("[minimuxer] Trustcache: \(trustcacheURL.path)")
        verboseLog("[minimuxer] Manifest:   \(manifestURL.path)")

        let imageData      = try Data(contentsOf: imageURL)
        let trustcacheData = try Data(contentsOf: trustcacheURL)
        let manifestData   = try Data(contentsOf: manifestURL)

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
