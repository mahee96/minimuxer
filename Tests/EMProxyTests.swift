//
//  EMProxyTests.swift
//  MinimuxerTests
//
//  Created by Magesh K on 12/8/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import XCTest
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
}
