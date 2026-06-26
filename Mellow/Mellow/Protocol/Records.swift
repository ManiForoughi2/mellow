import Foundation
import OuraCore

// RingEventType helpers. authoritative name table in oura_core::enums
enum RingEventType {
    // structurally unknown types whose (ctr,sess) bytes are NOT a ringTimestamp,
    // conservative-skip (PROTOCOL.md §9.3)
    static func isStructurallyUnknown(_ tag: UInt8) -> Bool { tag == 0x33 || tag == 0x56 }

    // StateChange name for a state byte; falls back to STATE_<n> for unnamed values
    static func stateChangeName(_ state: Int) -> String {
        guard let cstr = oura_state_change_name(UInt8(truncatingIfNeeded: state)) else {
            return "STATE_\(state)"
        }
        defer { oura_string_free(cstr) }
        return String(cString: cstr)
    }
}

// decoded inner record: raw envelope plus typed extracts dashboards consume.
// fields is the human-readable view for debug inspector
struct DecodedRecord: Identifiable {
    let id = UUID()
    let receivedAtMs: UInt64
    let ringTime: UInt32
    let tag: UInt8
    let typeName: String
    var eventTimeMs: UInt64?          // interpolated; nil if no anchor / untrustworthy
    var fields: [(String, String)] = []

    // typed extracts (nil when N/A for this record type)
    var tempC: Double?
    var instantHrBpm: Double?
    var spo2Percent: Int?
    var hrvRmssdMs: Int?
    var hrvHrBpm: Int?
    var stateName: String?
    var debugText: String?
    var timeSync: (ringTime: UInt32, ringUnixApproxS: Int, token: UInt8)?
    var stepFeatureBytes: [UInt8]?

    // sleep extracts from ring's 0x6a SleepPeriodInfo / 0x76 bedtime
    var respiratoryRate: Double?      // breaths/min (0x6a breath)
    var sleepAvgHr: Double?           // avg HR over period (0x6a)
    var sleepState: Int?              // 0 = deep/SWS, 1 = light/REM-ish, 2 = wake
    var sleepMotionCount: Int?        // motion events in period (0x6a)
    var bedtimeStartRt: UInt32?       // ring-time of bedtime start (0x76)
    var bedtimeEndRt: UInt32?         // ring-time of bedtime end (0x76)

    var tagHex: String { String(format: "0x%02x", tag) }
}

// per-record decode over oura_core::app_records_json. wire decoders + derived
// health metrics (HR-from-IBI with quality filter, SpO2 average, HRV current pair,
// primary temp) run in Rust; this maps JSON back into DecodedRecord
enum RecordDecoder {

    // JSON shape from oura_app_records_json (one per inner record)
    private struct RawRecord: Decodable {
        let tag: UInt8
        let type: String
        let rt: UInt32
        let fields: [[String]]
        var temp_c: Double?
        var instant_hr_bpm: Double?
        var spo2_percent: Int?
        var hrv_rmssd_ms: Int?
        var hrv_hr_bpm: Int?
        var state_name: String?
        var debug_text: String?
        var step_feature_bytes: [UInt8]?
        var time_sync: TimeSync?
        // sleep fields (0x6a / 0x76)
        var respiratory_rate: Double?
        var sleep_avg_hr: Double?
        var sleep_state: Int?
        var sleep_motion_count: Int?
        var bedtime_start_rt: UInt32?
        var bedtime_end_rt: UInt32?

        struct TimeSync: Decodable {
            let ring_time: UInt32
            let ring_unix_approx_s: Int
            let token: UInt8
        }
    }

    // decode every inner record in one notify-char value. Rust core parses TLV
    // stream, decodes each record, derives health metrics in one call
    static func decodeNotification(_ value: [UInt8], receivedAtMs: UInt64) -> [DecodedRecord] {
        let raws: [RawRecord] = value.withUnsafeBufferPointer { buf -> [RawRecord] in
            guard let cstr = oura_app_records_json(buf.baseAddress, buf.count) else { return [] }
            defer { oura_string_free(cstr) }
            let data = Data(bytes: cstr, count: strlen(cstr))
            return (try? JSONDecoder().decode([RawRecord].self, from: data)) ?? []
        }
        return raws.map { r in
            var out = DecodedRecord(receivedAtMs: receivedAtMs,
                                    ringTime: r.rt,
                                    tag: r.tag,
                                    typeName: r.type)
            out.fields = r.fields.map { ($0.first ?? "", $0.count > 1 ? $0[1] : "") }
            out.tempC = r.temp_c
            out.instantHrBpm = r.instant_hr_bpm
            out.spo2Percent = r.spo2_percent
            out.hrvRmssdMs = r.hrv_rmssd_ms
            out.hrvHrBpm = r.hrv_hr_bpm
            out.stateName = r.state_name
            out.debugText = r.debug_text
            out.stepFeatureBytes = r.step_feature_bytes
            out.respiratoryRate = r.respiratory_rate
            out.sleepAvgHr = r.sleep_avg_hr
            out.sleepState = r.sleep_state
            out.sleepMotionCount = r.sleep_motion_count
            out.bedtimeStartRt = r.bedtime_start_rt
            out.bedtimeEndRt = r.bedtime_end_rt
            if let ts = r.time_sync {
                out.timeSync = (ts.ring_time, ts.ring_unix_approx_s, ts.token)
            }
            return out
        }
    }
}
