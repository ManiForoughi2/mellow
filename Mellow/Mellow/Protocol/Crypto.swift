import Foundation
import OuraCore

// AES-128-ECB handshake proof + auth_key extraction. wraps oura_core::crypto via C ABI
enum RingCrypto {

    enum CryptoError: Error, LocalizedError {
        case badKeyLength(Int)
        case badNonceLength(Int)
        case aesFailed(Int32)
        case markerNotFound
        case multipleMarkers(Int)

        var errorDescription: String? {
            switch self {
            case .badKeyLength(let n):   return "auth_key must be 16 bytes, got \(n)"
            case .badNonceLength(let n): return "nonce must be 15 bytes, got \(n)"
            case .aesFailed(let s):      return "AES-128-ECB failed (status \(s))"
            case .markerNotFound:        return "auth_key signature not found in realm file"
            case .multipleMarkers(let c): return "multiple auth_key candidates in realm file (\(c))"
            }
        }
    }

    // proof = AES_128_ECB(auth_key, nonce ‖ 0x01 ‖ PKCS5_FULL_BLOCK_PAD)[:16].
    // authKey 16 bytes, nonce 15 bytes
    static func handshakeProof(authKey: [UInt8], nonce: [UInt8]) throws -> [UInt8] {
        guard authKey.count == 16 else { throw CryptoError.badKeyLength(authKey.count) }
        guard nonce.count == 15 else { throw CryptoError.badNonceLength(nonce.count) }
        var out = [UInt8](repeating: 0, count: 16)
        let rc = authKey.withUnsafeBufferPointer { keyPtr in
            nonce.withUnsafeBufferPointer { noncePtr in
                out.withUnsafeMutableBufferPointer { outPtr in
                    oura_handshake_proof(keyPtr.baseAddress, keyPtr.count,
                                         noncePtr.baseAddress, noncePtr.count,
                                         outPtr.baseAddress)
                }
            }
        }
        guard rc == 0 else { throw CryptoError.aesFailed(rc) }
        return out
    }

    // marker bytes immediately preceding the 16-byte auth_key in assa-store.realm
    static let authKeyMarker: [UInt8] = [0x41, 0x41, 0x41, 0x41, 0x11, 0x00, 0x00, 0x10]

    // scan realm for auth_key; throws if marker missing or ambiguous
    static func extractAuthKey(fromRealm data: Data) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        let rc = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int32 in
            out.withUnsafeMutableBufferPointer { outPtr in
                oura_extract_auth_key(raw.bindMemory(to: UInt8.self).baseAddress,
                                      raw.count, outPtr.baseAddress)
            }
        }
        switch rc {
        case 0: return out
        case 2: throw CryptoError.multipleMarkers(2)
        default: throw CryptoError.markerNotFound
        }
    }
}
