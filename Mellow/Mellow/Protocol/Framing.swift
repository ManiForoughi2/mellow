import Foundation

// wire framing, sibling of oura_core::framing.
// two layers share both characteristics; one ATT value carries one or the other,
// never both. first byte disambiguates: known outer opcode = outer frame stream,
// else inner TLV record stream (§2.3 PROTOCOL.md)
enum Framing {

    // outer-frame opcode catalog (§4.1), bidirectional phone<->ring
    static let opcodes: [UInt8: String] = [
        0x06: "identity_req",    0x07: "identity_resp",
        0x08: "time_or_id_req",  0x09: "time_or_id_resp",
        0x0c: "battery_req",     0x0d: "battery_resp",
        0x0e: "soft_reset_req",  0x0f: "soft_reset_ack",
        0x10: "history_fetch",   0x11: "history_fetch_resp",
        0x12: "time_sync_req",   0x13: "time_sync_resp",
        0x16: "subscribe",       0x17: "subscribe_ack",
        0x18: "event_subscribe", 0x19: "event_resp",
        0x1c: "state_cmd",       0x1d: "state_cmd_resp",
        0x1e: "state_query",     0x1f: "state_query_resp",
        0x24: "fw_authorize",
        0x28: "data_flush",      0x29: "data_flush_ack",
        0x2b: "fw_progress",
        0x2c: "fw_bulk",
        0x2f: "secure_session",
    ]

    struct OuterFrame {
        let opcode: UInt8
        let subOp: UInt8?     // first byte of body, by convention
        let body: [UInt8]     // everything after length, including subOp
        let raw: [UInt8]      // whole frame including opcode + length

        var name: String { Framing.opcodes[opcode] ?? String(format: "unknown_%02x", opcode) }
    }

    static func looksLikeOuterFrame(_ value: [UInt8]) -> Bool {
        guard let first = value.first else { return false }
        return opcodes[first] != nil
    }

    // zero or more outer frames packed into one ATT value
    static func parseOuterFrames(_ value: [UInt8]) -> [OuterFrame] {
        var out: [OuterFrame] = []
        var i = 0
        while i + 2 <= value.count {
            let op = value[i]
            let ln = Int(value[i + 1])
            if opcodes[op] == nil || i + 2 + ln > value.count { break }
            let body = Array(value[(i + 2)..<(i + 2 + ln)])
            let sub = ln >= 1 ? body[0] : nil
            out.append(OuterFrame(opcode: op, subOp: sub, body: body, raw: Array(value[i..<(i + 2 + ln)])))
            i += 2 + ln
        }
        return out
    }
}
