//
//  WirelessPair.swift
//  Minimuxer
//
//  Created by Magesh K on 04/07/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation

// MARK: - FFI Declarations

internal typealias WirelessPairReadyCallback = @convention(c) (
    _ ctx: UnsafeMutableRawPointer?,
    _ serviceId: UnsafePointer<Int8>?,
    _ port: UInt16,
    _ txtKeys: UnsafePointer<UnsafePointer<Int8>?>?,
    _ txtVals: UnsafePointer<UnsafePointer<Int8>?>?,
    _ txtCount: Int
) -> Void

internal typealias WirelessPairPinCallback = @convention(c) (
    _ pin: UnsafePointer<Int8>?,
    _ ctx: UnsafeMutableRawPointer?
) -> Void

internal struct WirelessPairResult {
    var error: UnsafeMutablePointer<Int8>? = nil
    var device_name: UnsafeMutablePointer<Int8>? = nil
    var device_model: UnsafeMutablePointer<Int8>? = nil
    var device_udid: UnsafeMutablePointer<Int8>? = nil
    var pairing_file_path: UnsafeMutablePointer<Int8>? = nil
    var host_alt_irk_hex: UnsafeMutablePointer<Int8>? = nil
}

@_silgen_name("wirelesspair_run_host")
internal func _wirelesspair_run_host(
    _ bindAddr: UnsafePointer<Int8>?,
    _ port: UInt16,
    _ name: UnsafePointer<Int8>?,
    _ model: UnsafePointer<Int8>?,
    _ outPath: UnsafePointer<Int8>?,
    _ readyCb: WirelessPairReadyCallback?,
    _ pinCb: WirelessPairPinCallback?,
    _ ctx: UnsafeMutableRawPointer?,
    _ out: UnsafeMutablePointer<WirelessPairResult>?
) -> Int32

@_silgen_name("wirelesspair_result_free")
internal func _wirelesspair_result_free(_ r: UnsafeMutablePointer<WirelessPairResult>?)

@_silgen_name("wirelesspair_stop")
internal func _wirelesspair_stop()










// MARK: - Wireless Pair API

public final class WirelessPair {
    
    public struct PairedDevice {
        public let name: String
        public let model: String
        public let udid: String
        public let pairingFilePath: String
    }
    
    public enum Error: LocalizedError {
        case pairingFailed(String)
        
        public var errorDescription: String? {
            switch self {
            case .pairingFailed(let msg): return msg
            }
        }
    }
    
    private var netService: NetService?
    private var isPairing = false
    
    public var onPinReceived: ((String) -> Void)?
    public var onReadyToPair: ((String, Int) -> Void)?
    
    public init() {}
    
    public func start(
        hostName: String = "SideStore",
        hostModel: String = "Mac17,7",
        outPath: String,
        completion: @escaping (Result<PairedDevice, Swift.Error>) -> Void
    ) {
        guard !isPairing else { return }
        isPairing = true
        
        let ctxBits = UInt(bitPattern: Unmanaged.passRetained(self).toOpaque())
        
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            
            let ctx = UnsafeMutableRawPointer(bitPattern: ctxBits)
            var result = WirelessPairResult()
            
            let rc = _wirelesspair_run_host(
                "0.0.0.0", 0, hostName, hostModel, outPath,
                readyCallback, pinCallback, ctx, &result
            )
            
            if let ctx = ctx {
                Unmanaged<WirelessPair>.fromOpaque(ctx).release()
            }
            
            let outcome: Result<PairedDevice, Swift.Error>
            if rc == 0 {
                let device = PairedDevice(
                    name: String(cString: result.device_name!),
                    model: String(cString: result.device_model!),
                    udid: String(cString: result.device_udid!),
                    pairingFilePath: String(cString: result.pairing_file_path!)
                )
                outcome = .success(device)
            } else {
                let msg = result.error != nil ? String(cString: result.error!) : "Unknown FFI error code \(rc)"
                outcome = .failure(Error.pairingFailed(msg))
            }
            
            _wirelesspair_result_free(&result)
            
            await MainActor.run {
                self.stopAdvertising()
                self.isPairing = false
                completion(outcome)
            }
        }
    }
    
    public func stop() {
        stopAdvertising()
        isPairing = false
        _wirelesspair_stop()
    }
    
    fileprivate func startAdvertising(serviceID: String, port: Int, txt: [String: Data]) {
        stopAdvertising()
        let service = NetService(
            domain: "",
            type: "_remotepairing-pairable-host._tcp.",
            name: serviceID,
            port: Int32(port)
        )
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        service.publish()
        netService = service
        onReadyToPair?(serviceID, port)
    }
    
    private func stopAdvertising() {
        netService?.stop()
        netService = nil
    }
}

private let readyCallback: WirelessPairReadyCallback = { ctx, serviceID, port, keys, vals, count in
    guard let ctx = ctx, let serviceID = serviceID else { return }
    let pairing = Unmanaged<WirelessPair>.fromOpaque(ctx).takeUnretainedValue()
    let id = String(cString: serviceID)
    
    var txt: [String: Data] = [:]
    if let keys = keys, let vals = vals {
        for i in 0..<count {
            guard let k = keys[i], let v = vals[i] else { continue }
            txt[String(cString: k)] = Data(String(cString: v).utf8)
        }
    }
    
    Task { @MainActor in
        pairing.startAdvertising(serviceID: id, port: Int(port), txt: txt)
    }
}

private let pinCallback: WirelessPairPinCallback = { pin, ctx in
    guard let ctx = ctx, let pin = pin else { return }
    let pairing = Unmanaged<WirelessPair>.fromOpaque(ctx).takeUnretainedValue()
    let pinString = String(cString: pin)
    
    Task { @MainActor in
        pairing.onPinReceived?(pinString)
    }
}
