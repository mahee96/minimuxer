//
//  MinimuxerBridgeIdevice.swift
//  Minimuxer
//
//  Created by s s on 2026/4/3.
//

import Foundation

// MARK: - FFI Declarations

internal struct RustIdeviceFfiError {
	let code: Int32
	let message: UnsafePointer<Int8>?
}

@_silgen_name("idevice_error_free")
internal func _idevice_error_free(_ err: UnsafeMutablePointer<RustIdeviceFfiError>?)

@_silgen_name("rust_bridge_idevice_test_device_connection")
internal func _rust_bridge_idevice_test_device_connection() -> Bool

@_silgen_name("rust_bridge_idevice_fetch_udid")
internal func _rust_bridge_idevice_fetch_udid(
	_ udidOut: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?
) -> UnsafeMutablePointer<RustIdeviceFfiError>?

@_silgen_name("rust_bridge_idevice_free_string")
internal func _rust_bridge_idevice_free_string(_ ptr: UnsafeMutablePointer<Int8>?)

@_silgen_name("rust_bridge_idevice_yeet_app_afc")
internal func _rust_bridge_idevice_yeet_app_afc(
	_ bundleId: UnsafePointer<Int8>?,
	_ ipaPtr: UnsafePointer<UInt8>?,
	_ ipaLen: UInt32
) -> UnsafeMutablePointer<RustIdeviceFfiError>?

@_silgen_name("rust_bridge_idevice_install_ipa")
internal func _rust_bridge_idevice_install_ipa(
	_ bundleId: UnsafePointer<Int8>?
) -> UnsafeMutablePointer<RustIdeviceFfiError>?

@_silgen_name("rust_bridge_idevice_remove_app")
internal func _rust_bridge_idevice_remove_app(
	_ bundleId: UnsafePointer<Int8>?
) -> UnsafeMutablePointer<RustIdeviceFfiError>?

@_silgen_name("rust_bridge_idevice_debug_app")
internal func _rust_bridge_idevice_debug_app(
	_ appId: UnsafePointer<Int8>?
) -> UnsafeMutablePointer<RustIdeviceFfiError>?

@_silgen_name("rust_bridge_idevice_debug_process")
internal func _rust_bridge_idevice_debug_process(
    _ pid: UInt32
) -> UnsafeMutablePointer<RustIdeviceFfiError>?

@_silgen_name("rust_bridge_idevice_install_provisioning_profile")
internal func _rust_bridge_idevice_install_provisioning_profile(
	_ profilePtr: UnsafePointer<UInt8>?,
	_ profileLen: UInt32
) -> UnsafeMutablePointer<RustIdeviceFfiError>?

@_silgen_name("rust_bridge_idevice_remove_provisioning_profile")
internal func _rust_bridge_idevice_remove_provisioning_profile(
	_ id: UnsafePointer<Int8>?
) -> UnsafeMutablePointer<RustIdeviceFfiError>?

@_silgen_name("rust_bridge_idevice_dump_provisioning_profile")
internal func _rust_bridge_idevice_dump_provisioning_profile(
	_ docsPath: UnsafePointer<Int8>?
) -> UnsafeMutablePointer<RustIdeviceFfiError>?

@_silgen_name("rust_bridge_idevice_set_rppairing_file")
internal func _rust_bridge_idevice_set_rppairing_file(
	_ pairingFile: UnsafePointer<Int8>?
) -> UnsafeMutablePointer<RustIdeviceFfiError>?

internal struct RustMountResult {
    let value: Int32
    let error: UnsafeMutablePointer<Int8>?
}

@_silgen_name("rust_bridge_idevice_mount_personalized_ddi")
internal func _rust_bridge_idevice_mount_personalized_ddi(
    _ image_ptr: UnsafePointer<UInt8>?, _ image_len: UInt32,
    _ trustcache_ptr: UnsafePointer<UInt8>?, _ trustcache_len: UInt32,
    _ manifest_ptr: UnsafePointer<UInt8>?, _ manifest_len: UInt32
) -> RustMountResult


// MARK: - Error Handling

public enum RustBridgeError: Error, LocalizedError, Equatable {
    case pairingFileRejected(description: String)
    case connectionReset(description: String)
    case unknown(code: Int, description: String)
    
    public var errorDescription: String? {
        switch self {
        case .pairingFileRejected(let description):
            return description
        case .connectionReset(let description):
            return description
        case .unknown(_, let description):
            return description
        }
    }
}

@inline(__always)
private func rustIdeviceThrowIfNeeded(_ error: UnsafeMutablePointer<RustIdeviceFfiError>?) throws {
	guard let error else {
		return
	}

	let rawMessage = error.pointee.message.map { String(cString: $0) } ?? "unknown error"
	let formattedMessage = formatNSSetAsJson(rawMessage)
	let code = Int(error.pointee.code)

	let swiftError: RustBridgeError
	if formattedMessage.contains("PairVerifyFailed") {
		swiftError = .pairingFileRejected(description: formattedMessage)
	} else if formattedMessage.contains("Connection reset by peer") || formattedMessage.contains("ConnectionReset") {
		swiftError = .connectionReset(description: formattedMessage)
	} else {
		swiftError = .unknown(code: code, description: formattedMessage)
	}

	_idevice_error_free(error)
	throw swiftError
}

fileprivate func formatNSSetAsJson(_ message: String) -> String {
    let normalized = message
        .replacingOccurrences(of: "\\r", with: "")
        .replacingOccurrences(of: "\r", with: "")
        .replacingOccurrences(of: "\\n", with: "\n")
        .replacingOccurrences(of: "\\\"", with: "\"")
        .replacingOccurrences(of: "\\t", with: "\t")
    
    var result = normalized
    
    while let startRange = result.range(of: "{("),
          let endRange = result.range(of: ")}") {
        
        guard startRange.upperBound < endRange.lowerBound else {
            break
        }
        
        let contentRange = startRange.upperBound..<endRange.lowerBound
        let content = String(result[contentRange])
        
        let plistString = "(\(content))"
        
        if let data = plistString.data(using: .utf8),
           let array = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String] {
            
            let sortedArray = array.sorted()
            let listString = sortedArray.map { "\"\($0)\"" }.joined(separator: ",\n")
            let jsonString = "[\n\(listString)\n]"
            
            let fullRange = startRange.lowerBound..<endRange.upperBound
            result.replaceSubrange(fullRange, with: jsonString)
            continue
        }
        
        break
    }
    
    return result
}

// MARK: - Swift Wrappers
public class RustIdevice {
	public static func testDeviceConnection() -> Bool {
		_rust_bridge_idevice_test_device_connection()
	}

	public static func fetchUDID() -> String? {
		var pointer: UnsafeMutablePointer<Int8>?
		let error = withUnsafeMutablePointer(to: &pointer) {
			_rust_bridge_idevice_fetch_udid($0)
		}

		do {
			try rustIdeviceThrowIfNeeded(error)
		} catch {
			return nil
		}

		guard let pointer else {
			return nil
		}

		defer { _rust_bridge_idevice_free_string(pointer) }
		return String(cString: pointer)
	}

	public static func yeetAppAfc(bundleId: String, ipaBytes: Data) throws {
		let error = ipaBytes.withUnsafeBytes { buffer in
			_rust_bridge_idevice_yeet_app_afc(
				bundleId,
				buffer.bindMemory(to: UInt8.self).baseAddress,
				UInt32(ipaBytes.count)
			)
		}

		try rustIdeviceThrowIfNeeded(error)
	}

	public static func installIpa(bundleId: String) throws {
		try rustIdeviceThrowIfNeeded(_rust_bridge_idevice_install_ipa(bundleId))
	}

	public static func removeApp(bundleId: String) throws {
		try rustIdeviceThrowIfNeeded(_rust_bridge_idevice_remove_app(bundleId))
	}

	public static func debugApp(appId: String) throws {
		try rustIdeviceThrowIfNeeded(_rust_bridge_idevice_debug_app(appId))
	}
    
    public static func debugApp(pid: UInt32) throws {
        try rustIdeviceThrowIfNeeded(_rust_bridge_idevice_debug_process(pid))
    }

	public static func installProvisioningProfile(_ profile: Data) throws {
		let error = profile.withUnsafeBytes { buffer in
			_rust_bridge_idevice_install_provisioning_profile(
				buffer.bindMemory(to: UInt8.self).baseAddress,
				UInt32(profile.count)
			)
		}

		try rustIdeviceThrowIfNeeded(error)
	}
    
    public static func dumpProfiles(_ docPath: String) throws {
		try rustIdeviceThrowIfNeeded(_rust_bridge_idevice_dump_provisioning_profile(docPath))
    }

	public static func removeProvisioningProfile(id: String) throws {
		try rustIdeviceThrowIfNeeded(_rust_bridge_idevice_remove_provisioning_profile(id))
	}

	public static func setRpPairingFile(_ pairingFile: String) throws {
		try rustIdeviceThrowIfNeeded(_rust_bridge_idevice_set_rppairing_file(pairingFile))
	}

    public static func mountPersonalizedDDI(image: Data, trustcache: Data, manifest: Data) throws {
        let result = image.withUnsafeBytes { imgBuf in
            trustcache.withUnsafeBytes { tcBuf in
                manifest.withUnsafeBytes { manBuf in
                    _rust_bridge_idevice_mount_personalized_ddi(
                        imgBuf.bindMemory(to: UInt8.self).baseAddress, UInt32(image.count),
                        tcBuf.bindMemory(to: UInt8.self).baseAddress, UInt32(trustcache.count),
                        manBuf.bindMemory(to: UInt8.self).baseAddress, UInt32(manifest.count)
                    )
                }
            }
        }
        if let errPtr = result.error {
            let msg = String(cString: errPtr)
            _rust_bridge_idevice_free_string(errPtr)
            let code = Int(result.value)
            
            let swiftError: RustBridgeError
            if msg.contains("PairVerifyFailed") {
                swiftError = .pairingFileRejected(description: msg)
            } else if msg.contains("Connection reset by peer") || msg.contains("ConnectionReset") {
                swiftError = .connectionReset(description: msg)
            } else {
                swiftError = .unknown(code: code, description: msg)
            }
            throw swiftError
        }
    }

}

