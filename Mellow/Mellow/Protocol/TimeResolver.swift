import Foundation
import OuraCore

// single-anchor linear ring_time to UTC interpolation. interpolation math + 0x42
// anchor-validation run in oura_core via time FFI
struct TimeAnchor: Codable {
    var ringTime: UInt64 = 0
    var utcMs: UInt64 = 0
    var factorFlag: UInt8 = 0   // 0 = 100 ms/tick, 1 = 1 ms/tick

    var isValid: Bool { ringTime != 0 && utcMs != 0 }
}

enum TimeResolver {
    // to_utc(target_rt, anchor); nil for invalid anchor
    static func toUtcMs(_ targetRt: UInt32, anchor: TimeAnchor) -> UInt64? {
        var out: UInt64 = 0
        let rc = oura_time_to_utc_ms(anchor.ringTime, anchor.utcMs, anchor.factorFlag,
                                     targetRt, &out)
        return rc == 0 ? out : nil
    }

    // anchor update from a fresh 0x42 API_TIME_SYNC_IND.
    // ringUnixApproxS = time_counter * 256; token 0xfd = burst factor flag.
    // validates candidate utc against nowMs (±48 h); nil if implausible
    static func anchorFromTimeSync(ringTime: UInt32,
                                   ringUnixApproxS: Int,
                                   token: UInt8,
                                   nowMs: UInt64) -> TimeAnchor? {
        var rt: UInt64 = 0
        var utc: UInt64 = 0
        var flag: UInt8 = 0
        let rc = oura_anchor_from_time_sync(ringTime, Int64(ringUnixApproxS), token, nowMs,
                                            &rt, &utc, &flag)
        guard rc == 0 else { return nil }
        return TimeAnchor(ringTime: rt, utcMs: utc, factorFlag: flag)
    }
}
