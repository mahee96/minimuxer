//
//  WirelessPairService.swift
//  Minimuxer
//
//  Created by Magesh K on 04/07/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
internal import MinimuxerCommon
internal import DeviceGatewayAPI
// import RustBridge

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
        
        Task.detached { [weak self] in
            guard let self = self else { return }
            
            let outcome: Result<WirelessPairPairedDevice, Swift.Error>
            do {
                let pairedDevice = try await Minimuxer.gateway.startWirelessPair(
                    hostName: hostName,
                    hostModel: hostModel,
                    outPath: outPath,
                    onReady: { [weak self] serviceID, port, txtRecords in
                        guard let self = self else { return }
                        var txt: [String: Data] = [:]
                        for (k, v) in txtRecords {
                            txt[k] = Data(v.utf8)
                        }
                        Task { @MainActor in
                            self.startAdvertising(serviceID: serviceID, port: Int(port), txt: txt)
                        }
                    },
                    onPin: { [weak self] pinString in
                        guard let self = self else { return }
                        Task { @MainActor in
                            self.onPinReceived?(pinString)
                        }
                    }
                )
                outcome = .success(pairedDevice)
            } catch {
                outcome = .failure(error)
            }
            
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
