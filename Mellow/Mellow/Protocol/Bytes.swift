import Foundation

// wire-format LE decoding lives in oura_core, not here

extension Data {
    var bytes: [UInt8] { [UInt8](self) }
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

extension Array where Element == UInt8 {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    // accepts "a1b2..." or "a1 b2 ..."; nil on bad input
    static func fromHex(_ s: String) -> [UInt8]? {
        let cleaned = s.lowercased().filter { $0.isHexDigit }
        guard cleaned.count % 2 == 0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(cleaned.count / 2)
        var idx = cleaned.startIndex
        while idx < cleaned.endIndex {
            let next = cleaned.index(idx, offsetBy: 2)
            guard let byte = UInt8(cleaned[idx..<next], radix: 16) else { return nil }
            out.append(byte)
            idx = next
        }
        return out
    }
}
