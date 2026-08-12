//
//  EMProxyTests.swift
//  MinimuxerTests
//
//  Created by Magesh K on 12/8/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import XCTest
import CryptoKit
import Network
@testable import Minimuxer

final class EMProxyTests: XCTestCase {
    func testEMProxyMinimuxerAPI() async throws {
        print("[EMProxyTests] Starting Minimuxer.emproxy...")
        try await Minimuxer.emproxy.start()

        print("[EMProxyTests] Testing end-to-end loopback connection & packet relay via testConnection()...")
        try await Minimuxer.emproxy.testConnection(timeoutMs: 1000)
        print("[EMProxyTests] testConnection() passed!")

        print("[EMProxyTests] Stopping Minimuxer.emproxy...")
        try await Minimuxer.emproxy.stop()
        print("[EMProxyTests] EMProxy test completed successfully!")
    }

    func testEMProxySwiftLoopbackConnection() async throws {
        print("[EMProxyTests] Starting Minimuxer.emproxy for pure Swift loopback test...")
        try await Minimuxer.emproxy.start()

        print("[EMProxyTests] Executing Swift UDP loopback packet exchange...")
        let testPayload = "SideStore-EMP-Test-Payload".data(using: .utf8)!
        let isPayloadIntact = try verifySwiftUDPLoopbackPacketExchange(port: 39482, testPayload: testPayload)
        XCTAssertTrue(isPayloadIntact, "Pure Swift loopback test packet exchange failed")

        print("[EMProxyTests] Stopping Minimuxer.emproxy...")
        try await Minimuxer.emproxy.stop()
        print("[EMProxyTests] Pure Swift loopback test completed successfully!")
    }

    func testEMProxyWireGuardHandshakePacket() async throws {
        print("[EMProxyTests] Starting Minimuxer.emproxy for WireGuard handshake test...")
        try await Minimuxer.emproxy.start()

        let testPort: UInt16 = 51820
        print("[EMProxyTests] Sending WireGuard handshake initiation packet to 127.0.0.1:\(testPort)...")
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: testPort)!, using: .udp)
        connection.start(queue: .global())

        let handshakePacket = try makeWireGuardHandshakeInitiationPacket()
        connection.send(content: handshakePacket, completion: .idempotent)
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms
        connection.cancel()

        print("[EMProxyTests] Stopping Minimuxer.emproxy...")
        try await Minimuxer.emproxy.stop()
        print("[EMProxyTests] WireGuard handshake test completed!")
    }
}

// Private Helper Extensions Describing Verification Methods

private extension EMProxyTests {
    func verifySwiftUDPLoopbackPacketExchange(port: UInt16, testPayload: Data) throws -> Bool {
        let listener = try NWListener(using: .udp, on: NWEndpoint.Port(rawValue: port)!)
        let receivedExpectation = expectation(description: "UDP loopback payload received")
        var receivedData: Data?

        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receiveMessage { data, _, _, _ in
                receivedData = data
                receivedExpectation.fulfill()
                connection.cancel()
            }
        }
        listener.start(queue: .global())
        defer { listener.cancel() }

        dispatchUDPSender(port: port, payload: testPayload)

        wait(for: [receivedExpectation], timeout: 3.0)
        return receivedData == testPayload
    }

    func dispatchUDPSender(port: UInt16, payload: Data) {
        DispatchQueue.global().async {
            let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .udp)
            connection.start(queue: .global())
            connection.send(content: payload, completion: .idempotent)
            usleep(100_000)
            connection.cancel()
        }
    }

    func makeWireGuardHandshakeInitiationPacket() throws -> Data {
        let clientPrivRaw = Data(base64Encoded: "AIIeeUDvk3NeAFJ9BWCQvPJize/9WZibMnGJ/0rt5k4=")!
        let serverPubRaw = Data(base64Encoded: "kHDoekeYhBvfW9a9UQ+UCmpbG423eejTjcjW+DT+JF0=")!

        let clientPriv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: clientPrivRaw)
        let serverPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: serverPubRaw)

        let ephemeralPriv = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralPub = ephemeralPriv.publicKey.rawRepresentation

        var h = SHA256.hash(data: Data("Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s".utf8))
        let construction = Data("WireGuard v1 zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz".utf8)
        h = SHA256.hash(data: Data(h) + construction)
        h = SHA256.hash(data: Data(h) + serverPubRaw)
        h = SHA256.hash(data: Data(h) + ephemeralPub)

        let sharedSecret1 = try ephemeralPriv.sharedSecretFromKeyAgreement(with: serverPub)
        let key1 = SymmetricKey(data: sharedSecret1)

        let clientPubRaw = clientPriv.publicKey.rawRepresentation
        let sealedStatic = try ChaChaPoly.seal(clientPubRaw, using: key1, nonce: ChaChaPoly.Nonce(data: Data(repeating: 0, count: 12)), authenticating: Data(h))
        let encryptedStatic = sealedStatic.ciphertext + sealedStatic.tag
        h = SHA256.hash(data: Data(h) + encryptedStatic)

        let sharedSecret2 = try clientPriv.sharedSecretFromKeyAgreement(with: serverPub)
        let key2 = SymmetricKey(data: sharedSecret2)

        let timestamp = Data(repeating: 0, count: 12)
        let sealedTimestamp = try ChaChaPoly.seal(timestamp, using: key2, nonce: ChaChaPoly.Nonce(data: Data(repeating: 0, count: 12)), authenticating: Data(h))
        let encryptedTimestamp = sealedTimestamp.ciphertext + sealedTimestamp.tag

        var packet = Data()
        packet.append(1)
        packet.append(contentsOf: [0, 0, 0])
        packet.append(contentsOf: [1, 0, 0, 0])
        packet.append(ephemeralPub)
        packet.append(encryptedStatic)
        packet.append(encryptedTimestamp)
        packet.append(contentsOf: Data(repeating: 0, count: 32))

        return packet
    }
}
