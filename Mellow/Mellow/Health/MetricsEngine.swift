import Foundation
import OuraCore

// decoded from oura_recovery_json; sub-scores nil when input+baseline omitted
struct RecoveryResult: Codable {
    let score: Double
    let hrv_score: Double?
    let resting_hr_score: Double?
    let respiratory_rate_score: Double?
    let sleep_score: Double?
}

// decoded from oura_sleep_score_json; sub-scores nil when input omitted
struct SleepScoreResult: Codable {
    let score: Double
    let duration: Double?
    let efficiency: Double?
    let rem: Double?
    let deep: Double?
    let latency: Double?
    let restfulness: Double?
    let timing: Double?
}

// facade over Rust OuraCore derived-score C ABI. char*->JSON->Codable idiom from
// RecordDecoder. core returns 0.0 sentinel for "no answer", mapped to nil where
// signature is optional so callers dont confuse it with a real zero
enum MetricsEngine {

    // MARK: - Scalars

    // Tanaka age-predicted max HR (208 - 0.7*age)
    static func hrMaxTanaka(age: Double) -> Double {
        oura_hr_max_tanaka(age)
    }

    // non-exercise VO2max (15*HRmax/HRrest); nil on core 0.0 bad-input sentinel
    static func vo2max(hrMax: Double, hrRest: Double) -> Double? {
        let v = oura_vo2max_hr_ratio(hrMax, hrRest)
        return v == 0.0 ? nil : v
    }

    // resting HR (low-percentile of day's HR); nil on no samples or 0.0 sentinel
    static func restingHR(hrSamples: [Double], percentile: Double = 0.05) -> Double? {
        guard !hrSamples.isEmpty else { return nil }
        let req: [String: Any] = ["hr": hrSamples, "percentile": percentile]
        guard let json = Self.jsonString(req) else { return nil }
        let v = json.withCString { oura_resting_hr($0) }
        return v == 0.0 ? nil : v
    }

    // RMSSD (ms) from IBI series (ms); nil for fewer than 2 intervals or 0.0 sentinel
    static func rmssd(ibiMs: [Double]) -> Double? {
        guard ibiMs.count >= 2 else { return nil }
        let req: [String: Any] = ["ibi": ibiMs]
        guard let json = Self.jsonString(req) else { return nil }
        let v = json.withCString { oura_rmssd($0) }
        return v == 0.0 ? nil : v
    }

    // day strain 0-21 from per-segment (bpm, minutes) + HR bounds; 0.0 is a real result here
    static func strain(bpm: [Double], minutes: [Double], hrMax: Double, hrRest: Double) -> Double {
        let req: [String: Any] = ["bpm": bpm, "minutes": minutes, "hr_max": hrMax, "hr_rest": hrRest]
        guard let json = Self.jsonString(req) else { return 0.0 }
        return json.withCString { oura_strain($0) }
    }

    // MARK: - Compound scores

    // recovery 0-100 + sub-scores. nil args omitted from request so core uses its
    // defaults / leaves matching sub-score nil. baselineRMSSD sent only when non-empty
    static func recovery(rmssd: Double?,
                         restingHR: Double?,
                         respiratoryRate: Double?,
                         sleepPerformance: Double?,
                         baselineRMSSD: [Double],
                         baselineRestingHR: Double?,
                         baselineRespiratoryRate: Double?) -> RecoveryResult {
        var req: [String: Any] = [:]
        if let v = rmssd { req["rmssd"] = v }
        if let v = restingHR { req["resting_hr"] = v }
        if let v = respiratoryRate { req["respiratory_rate"] = v }
        if let v = sleepPerformance { req["sleep_performance"] = v }
        if !baselineRMSSD.isEmpty { req["baseline_rmssd"] = baselineRMSSD }
        if let v = baselineRestingHR { req["baseline_resting_hr"] = v }
        if let v = baselineRespiratoryRate { req["baseline_respiratory_rate"] = v }
        return Self.decodeCompound(req, call: oura_recovery_json)
            ?? RecoveryResult(score: 0, hrv_score: nil, resting_hr_score: nil,
                              respiratory_rate_score: nil, sleep_score: nil)
    }

    // sleep score 0-100 + sub-scores. nil args omitted so core only scores given dimensions
    static func sleepScore(totalSleepMin: Double?,
                           timeInBedMin: Double?,
                           remMin: Double?,
                           deepMin: Double?,
                           latencyMin: Double?,
                           awakenings: Int?,
                           midpointHour: Double?) -> SleepScoreResult {
        var req: [String: Any] = [:]
        if let v = totalSleepMin { req["total_sleep_min"] = v }
        if let v = timeInBedMin { req["time_in_bed_min"] = v }
        if let v = remMin { req["rem_min"] = v }
        if let v = deepMin { req["deep_min"] = v }
        if let v = latencyMin { req["latency_min"] = v }
        if let v = awakenings { req["awakenings"] = v }
        if let v = midpointHour { req["midpoint_hour"] = v }
        return Self.decodeCompound(req, call: oura_sleep_score_json)
            ?? SleepScoreResult(score: 0, duration: nil, efficiency: nil, rem: nil,
                                deep: nil, latency: nil, restfulness: nil, timing: nil)
    }

    // MARK: - FFI helpers

    // sorted keys for deterministic output
    private static func jsonString(_ obj: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    // copy C result via Data(bytes:count:), decode, oura_string_free
    private static func decodeCompound<T: Decodable>(_ req: [String: Any],
                                                     call: (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?) -> T? {
        guard let json = Self.jsonString(req) else { return nil }
        return json.withCString { ptr -> T? in
            guard let cstr = call(ptr) else { return nil }
            defer { oura_string_free(cstr) }
            let data = Data(bytes: cstr, count: strlen(cstr))
            return try? JSONDecoder().decode(T.self, from: data)
        }
    }
}
