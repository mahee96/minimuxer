//
//  WirelessPairService.swift
//  Minimuxer
//
//  Created by Magesh K on 04/07/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import RustBridge

// MARK: - Wireless Pair API

final internal class WirelessPairService: WirelessPairAPI {
    
    private var netService: NetService?
    private var isPairing = false
    
    var onPinReceived: ((String) -> Void)?
    var onReadyToPair: ((String, Int) -> Void)?
    
    init() {}
    
    func start(
        hostName: String = MinimuxerConstants.defaultHostName,
        hostModel: String = MinimuxerConstants.defaultHostModel,
        outPath: String,
        completion: @escaping (Result<WirelessPairPairedDevice, Swift.Error>) -> Void
    ) {
        guard !isPairing else { return }
        isPairing = true
        
        let ctxBits = UInt(bitPattern: Unmanaged.passRetained(self).toOpaque())
        
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            
            let ctx = UnsafeMutableRawPointer(bitPattern: ctxBits)
            var result = WirelessPairResult()
            
            let rc = _wirelesspair_run_host(
                MinimuxerConstants.defaultBindIP, MinimuxerConstants.defaultBindPort, hostName, hostModel, outPath,
                readyCallback, pinCallback, ctx, &result
            )
            
            if let ctx = ctx {
                Unmanaged<WirelessPairService>.fromOpaque(ctx).release()
            }
            
            let outcome: Result<WirelessPairPairedDevice, Swift.Error>
            if rc == 0 {
                let device = WirelessPairPairedDevice(
                    name: String(cString: result.device_name!),
                    model: String(cString: result.device_model!),
                    udid: String(cString: result.device_udid!),
                    pairingFilePath: String(cString: result.pairing_file_path!)
                )
                outcome = .success(device)
            } else {
                let msg = result.error != nil ? String(cString: result.error!) : "Unknown FFI error code \(rc)"
                outcome = .failure(MinimuxerInternalError.pairingFailed(msg))
            }
            
            _wirelesspair_result_free(&result)
            
            await MainActor.run {
                self.stopAdvertising()
                self.isPairing = false
                completion(outcome)
            }
        }
    }
    
    func stop() {
        stopAdvertising()
        isPairing = false
        _wirelesspair_stop()
    }
    
    fileprivate func startAdvertising(serviceID: String, port: Int, txt: [String: Data]) {
        stopAdvertising()
        let service = NetService(
            domain: MinimuxerConstants.defaultAdDomain,
            type: MinimuxerConstants.remotepairingServiceType,
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
    let pairing = Unmanaged<WirelessPairService>.fromOpaque(ctx).takeUnretainedValue()
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
    let pairing = Unmanaged<WirelessPairService>.fromOpaque(ctx).takeUnretainedValue()
    let pinString = String(cString: pin)
    
    Task { @MainActor in
        pairing.onPinReceived?(pinString)
    }
}
