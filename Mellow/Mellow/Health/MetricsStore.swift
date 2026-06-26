import Foundation
import Combine

@MainActor
final class MetricsStore: ObservableObject {

    // sorted oldest -> newest
    @Published var summaries: [DailySummary] = []

    // MARK: - Convenience accessors

    var today: DailySummary? { summaries.last }

    // up-to-14 day HRV baseline window recovery normalizes against
    var baselineRMSSD: [Double] {
        Self.lastValues(summaries.compactMap { $0.hrvRMSSD }, count: 14)
    }

    var baselineRestingHR: Double? {
        Self.mean(Self.lastValues(summaries.compactMap { $0.restingHR }, count: 14))
    }

    var baselineRespiratoryRate: Double? {
        Self.mean(Self.lastValues(summaries.compactMap { $0.respiratoryRate }, count: 14))
    }

    // MARK: - Persistence

    private static var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mellow_metrics.json")
    }

    func persist() {
        if let data = try? JSONEncoder().encode(summaries) {
            try? data.write(to: Self.storeURL, options: .atomic)
        }
    }

    func loadPersisted() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let s = try? JSONDecoder().decode([DailySummary].self, from: data) else { return }
        summaries = s.sorted { $0.date < $1.date }
    }

    // MARK: - Recompute

    // "yyyy-MM-dd" in local tz so a night maps to its local day
    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar.current
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // recovery baselines built from PRIOR days only, walking chronologically
    func recompute(from store: RingStore, age: Double) {
        let hrByDay = Self.groupByDay(store.hrHistory)
        let hrvByDay = Self.groupByDay(store.hrvHistory)
        let tempByDay = Self.groupByDay(store.tempHistory)

        // any day with any data gets a row
        let allKeys = Set(hrByDay.keys).union(hrvByDay.keys).union(tempByDay.keys)
        let sortedKeys = allKeys.sorted()  // "yyyy-MM-dd" sorts chronologically

        let hrMax = MetricsEngine.hrMaxTanaka(age: age)

        // build chronologically so each day's recovery sees baselines from prior
        // days computed in this pass
        var computed: [DailySummary] = []

        for key in sortedKeys {
            let hrSamples = hrByDay[key] ?? []
            let hrvSamples = hrvByDay[key] ?? []
            let tempSamples = tempByDay[key] ?? []

            let dayDate = Self.startOfDay(forKey: key,
                                          fallback: hrSamples.first?.date
                                            ?? hrvSamples.first?.date
                                            ?? tempSamples.first?.date
                                            ?? Date())

            let hrValues = hrSamples.map(\.value)
            let restingHR = MetricsEngine.restingHR(hrSamples: hrValues)

            // ring reports RMSSD directly in hrvHistory; day median for robustness
            let hrvRMSSD = Self.median(hrvSamples.map(\.value))

            let skinTempC = Self.mean(tempSamples.map(\.value))

            // ring's per-night aggregation (0x6a stages+breaths, 0x76 bedtime)
            let night = store.sleepNights[key]

            // night median breaths/min from 0x6a
            let respiratoryRate: Double? = night?.medianRespiratoryRate

            // VO2max needs a resting HR to anchor the ratio
            let vo2max: Double? = restingHR.flatMap {
                MetricsEngine.vo2max(hrMax: hrMax, hrRest: $0)
            }

            // each consecutive HR pair = segment, minutes capped so sparse
            // store-and-forward history cant inflate load
            let (bpm, minutes) = Self.strainSegments(hrSamples)
            let strain: Double? = bpm.isEmpty
                ? nil
                : MetricsEngine.strain(bpm: bpm, minutes: minutes,
                                       hrMax: hrMax, hrRest: restingHR ?? 60)

            // prefer ring's per-night staging (0x6a); else fall back to coarse in-bed window
            var totalSleepMin: Double? = nil
            var sleepPerformance: Double? = nil
            var sleepDetail: SleepScoreResult? = nil

            if let night = night, night.asleepMin > 0 {
                // ring's 3-state tag merges light+REM; split REM as ~25% of combined
                // light+REM bucket, remainder is light. deep reported directly
                let asleep = night.asleepMin
                let inBed = night.inBedMin > 0 ? night.inBedMin : asleep
                let remMin = night.lightRemMin * 0.25
                let deepMin = night.deepMin
                let midpointHour = Self.midpointHour(startMs: night.startMs, endMs: night.endMs)
                totalSleepMin = asleep
                sleepPerformance = min(100, asleep / 480.0 * 100.0)
                sleepDetail = MetricsEngine.sleepScore(
                    totalSleepMin: asleep,
                    timeInBedMin: inBed,
                    remMin: remMin,
                    deepMin: deepMin,
                    latencyMin: nil,                // onset latency needs sleep-onset marker, not yet decoded
                    awakenings: night.awakenings,
                    midpointHour: midpointHour)
            } else if let start = store.sleepStartDate, let end = store.sleepEndDate, end > start,
                      Self.dayKeyFormatter.string(from: start) == key {
                // coarse window from in-bed flags; only duration/efficiency/timing scorable
                let mins = end.timeIntervalSince(start) / 60.0
                let midpointHour = Self.midpointHour(startMs: UInt64(start.timeIntervalSince1970 * 1000),
                                                     endMs: UInt64(end.timeIntervalSince1970 * 1000))
                totalSleepMin = mins
                sleepPerformance = min(100, mins / 480.0 * 100.0)
                sleepDetail = MetricsEngine.sleepScore(totalSleepMin: mins,
                                                       timeInBedMin: mins,
                                                       remMin: nil, deepMin: nil,
                                                       latencyMin: nil, awakenings: nil,
                                                       midpointHour: midpointHour)
            }

            // recovery uses tonight's values + baselines from PRIOR days only
            let recoveryDetail = MetricsEngine.recovery(
                rmssd: hrvRMSSD,
                restingHR: restingHR,
                respiratoryRate: respiratoryRate,
                sleepPerformance: sleepPerformance,
                baselineRMSSD: Self.lastValues(computed.compactMap { $0.hrvRMSSD }, count: 14),
                baselineRestingHR: Self.mean(Self.lastValues(computed.compactMap { $0.restingHR }, count: 14)),
                baselineRespiratoryRate: Self.mean(Self.lastValues(computed.compactMap { $0.respiratoryRate }, count: 14)))
            // recovery row only makes sense if some input drove it
            let haveRecoveryInput = hrvRMSSD != nil || restingHR != nil
                || sleepPerformance != nil || respiratoryRate != nil

            let summary = DailySummary(
                id: key,
                date: dayDate,
                restingHR: restingHR,
                hrvRMSSD: hrvRMSSD,
                respiratoryRate: respiratoryRate,
                skinTempC: skinTempC,
                recovery: haveRecoveryInput ? recoveryDetail.score : nil,
                strain: strain,
                sleepScore: sleepDetail?.score,
                totalSleepMin: totalSleepMin,
                vo2max: vo2max,
                recoveryDetail: haveRecoveryInput ? recoveryDetail : nil,
                sleepDetail: sleepDetail)

            computed.append(summary)
        }

        // replace same-day rows, keep days with no current history, stay sorted by date
        var byKey: [String: DailySummary] = [:]
        for s in summaries { byKey[s.id] = s }
        for s in computed { byKey[s.id] = s }
        summaries = byKey.values.sorted { $0.date < $1.date }

        persist()
    }

    // MARK: - Grouping / stats helpers

    // each bucket sorted by time so consecutive-pair (strain) logic is well defined
    private static func groupByDay(_ samples: [RingStore.Sample]) -> [String: [RingStore.Sample]] {
        var out: [String: [RingStore.Sample]] = [:]
        for s in samples {
            let key = dayKeyFormatter.string(from: s.date)
            out[key, default: []].append(s)
        }
        for k in out.keys { out[k]?.sort { $0.timeMs < $1.timeMs } }
        return out
    }

    // each pair: bpm is later sample, minutes is inter-sample gap clamped to [0,cap]
    // cap stops a long quiet stretch (sparse store-and-forward sync) inflating load
    private static func strainSegments(_ samples: [RingStore.Sample],
                                       capMinutes: Double = 5.0) -> (bpm: [Double], minutes: [Double]) {
        guard samples.count >= 2 else { return ([], []) }
        var bpm: [Double] = []
        var minutes: [Double] = []
        for i in 1..<samples.count {
            let gapMin = Double(samples[i].timeMs &- samples[i - 1].timeMs) / 60_000.0
            let clamped = max(0.0, min(capMinutes, gapMin))
            guard clamped > 0 else { continue }
            bpm.append(samples[i].value)
            minutes.append(clamped)
        }
        return (bpm, minutes)
    }

    // local fractional hour (0-24) of sleep-window midpoint, for sleep-timing score
    private static func midpointHour(startMs: UInt64?, endMs: UInt64?) -> Double? {
        guard let s = startMs, let e = endMs, e >= s else { return nil }
        let midMs = s + (e - s) / 2
        let date = Date(timeIntervalSince1970: Double(midMs) / 1000.0)
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        guard let h = comps.hour, let m = comps.minute else { return nil }
        return Double(h) + Double(m) / 60.0
    }

    // fallback used if key fails to parse
    private static func startOfDay(forKey key: String, fallback: Date) -> Date {
        guard let parsed = dayKeyFormatter.date(from: key) else { return fallback }
        return Calendar.current.startOfDay(for: parsed)
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let n = sorted.count
        if n % 2 == 1 { return sorted[n / 2] }
        return (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
    }

    private static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func lastValues(_ values: [Double], count: Int) -> [Double] {
        guard values.count > count else { return values }
        return Array(values.suffix(count))
    }
}
