import Foundation
import Combine

@MainActor
final class RingStore: ObservableObject {

    struct Sample: Identifiable, Codable {
        var id = UUID()
        var timeMs: UInt64
        let value: Double
        // ring tick, kept to back-fill real UTC once anchor resolves (records can
        // arrive before the 0x42 anchor; until then timeMs is the receive-time estimate)
        var ringTime: UInt32 = 0
        var timeResolved: Bool = true
        var date: Date { Date(timeIntervalSince1970: Double(timeMs) / 1000.0) }
    }

    struct PacketLogEntry: Identifiable {
        let id = UUID()
        let timeMs: UInt64
        let direction: Direction
        let hex: String
        let note: String
        enum Direction { case rx, tx }
        var date: Date { Date(timeIntervalSince1970: Double(timeMs) / 1000.0) }
    }

    @Published var instantHrBpm: Double?
    @Published var spo2Percent: Int?
    @Published var hrvRmssdMs: Int?
    @Published var respiratoryRate: Double?   // breaths/min (latest, from 0x72 col3)
    @Published var skinTempC: Double?
    @Published var batteryVoltageMv: Int?
    @Published var batteryPercent: Int?
    @Published var wearStateName: String?
    // ring emits 0x7e/0x7f RealSteps records but their 14-byte payload isnt RE'd to
    // a count yet, so nil (UI shows "—") not a fabricated number
    // TODO: decode RealSteps payload -> set from latest 0x7e/0x7f
    @Published var stepsToday: Int?
    @Published var lastEventDate: Date?

    @Published var hrHistory: [Sample] = []
    @Published var tempHistory: [Sample] = []
    @Published var spo2History: [Sample] = []
    @Published var hrvHistory: [Sample] = []

    @Published var ppgWaveform: [Double] = []
    @Published var lastPPGDate: Date?
    @Published var isStreamingPPG: Bool = false
    @Published var sensorStateName: String?

    @Published var recentRecords: [DecodedRecord] = []
    @Published var packetLog: [PacketLogEntry] = []

    // sleep parsed from ring's own internal flags (0x43 debug records carry
    // in_bed=N and check_sleep). reconstruct a basic sleep window from what the
    // ring recorded, before full sleep-stage decoding
    @Published var inBed: Bool?              // last seen in_bed flag (nil = unknown)
    @Published var sleepStartDate: Date?     // first in_bed=1 in synced data
    @Published var sleepEndDate: Date?       // last in_bed=1
    @Published var sawSleepFlags: Bool = false

    // per-night sleep aggregation from ring's 0x6a SleepPeriodInfo records (stage
    // tag + respiratory rate per ~30s period) and 0x76 bedtime boundaries. keyed by
    // local "yyyy-MM-dd" of night start so metrics layer pulls stage minutes per day
    @Published var sleepNights: [String: SleepNight] = [:]

    struct SleepNight: Codable {
        // each 0x6a SleepPeriodInfo record covers this many seconds
        static let periodSeconds: Double = 30.0

        var dayKey: String
        var startMs: UInt64?
        var endMs: UInt64?
        var deepPeriods: Int = 0       // sleep_state == 0 (SWS)
        var lightRemPeriods: Int = 0   // sleep_state == 1
        var wakePeriods: Int = 0       // sleep_state == 2
        var awakenings: Int = 0        // transitions from asleep → wake
        var respiratoryRates: [Double] = []
        // sum + count of per-period average HR (0x6a average_hr) -> mean overnight HR
        var sleepAvgHrSum: Double = 0
        var sleepAvgHrCount: Int = 0
        var lastState: Int? = nil

        var avgHr: Double { sleepAvgHrCount > 0 ? sleepAvgHrSum / Double(sleepAvgHrCount) : 0 }

        var deepMin: Double { Double(deepPeriods) * Self.periodSeconds / 60.0 }
        // REM merged with light by ring's 3-state tag; expose combined light+REM
        var lightRemMin: Double { Double(lightRemPeriods) * Self.periodSeconds / 60.0 }
        var wakeMin: Double { Double(wakePeriods) * Self.periodSeconds / 60.0 }
        var asleepMin: Double { deepMin + lightRemMin }
        var inBedMin: Double { asleepMin + wakeMin }
        var medianRespiratoryRate: Double? {
            guard !respiratoryRates.isEmpty else { return nil }
            let s = respiratoryRates.sorted()
            return s[s.count / 2]
        }
    }

    @Published var statusLine: String = "Idle"
    @Published var isSyncing: Bool = false
    @Published var lastSyncDate: Date?
    @Published var recordsThisSession: Int = 0

    private let maxHistory = 600
    private let maxRecords = 300
    private let maxPackets = 500
    // ≈7.5 s at the ~16 Hz burst rate
    private let maxPPG = 120

    private var bpmEstimator = BPMEstimator()

    // MARK: - Recorded-HR cleanup (spike rejection + display smoothing)
    //
    // recorded HR (hrHistory) is one value PER IBI packet, too noisy to plot raw
    // (a single bad beat reads 33 or 143 bpm). (1) reject beat-to-beat jumps no
    // real heart produces before logging, (2) expose a rolling-median display
    // series. raw hrHistory untouched so HealthKit export + debug see every value.

    // cap on how far one accepted reading may differ from baseline. genuine HR
    // cant leap ~70 bpm between adjacent packets; such a jump is a motion beat
    private let maxHrStepBpm: Double = 25
    // plausible band for a recorded (resting/daytime) HR trend; loose at top for exertion
    private let recordedHrRange: ClosedRange<Double> = 35...190
    // EMA of accepted readings the spike gate compares against
    private var hrBaseline: Double?
    // consecutive rejections; after several assume baseline stale (HR moved) and re-seed
    private var hrRejectStreak = 0
    // samples for rolling-median display smoothing
    private let hrSmoothWindow = 5

    // spike gate for a freshly decoded recorded-HR value. returns value to log
    // (nudged toward baseline) or nil to drop as a beat-to-beat artifact. seeds on
    // first use, self-heals if HR truly shifts (sustained rejections re-seed)
    private func hrSpikeGate(_ hr: Double) -> Double? {
        guard recordedHrRange.contains(hr) else {
            // outside any plausible recorded HR; artifact
            hrRejectStreak += 1
            if hrRejectStreak >= 4, recordedHrRange.contains(hr) { hrBaseline = hr; hrRejectStreak = 0; return hr }
            return nil
        }
        guard let base = hrBaseline else {
            hrBaseline = hr
            return hr
        }
        if abs(hr - base) <= maxHrStepBpm {
            // accept; nudge baseline (EMA α≈0.4, tracks real drift not single-packet noise)
            hrBaseline = base + 0.4 * (hr - base)
            hrRejectStreak = 0
            return hrBaseline
        }
        // too big a jump. tolerate a few: a real sustained change shows as repeated
        // rejections in the same direction; on the 4th accept the new level + re-seed
        hrRejectStreak += 1
        if hrRejectStreak >= 4 {
            hrBaseline = hr
            hrRejectStreak = 0
            return hr
        }
        return nil
    }

    // sink for exporting metrics (wired to HealthKit by AppModel)
    var healthExport: ((DecodedRecord, Date) -> Void)?

    // MARK: - Persistence (so data survives app relaunch, like Oura)

    private struct Persisted: Codable {
        var hr: [Sample] = []
        var temp: [Sample] = []
        var spo2: [Sample] = []
        var hrv: [Sample] = []
        var lastHr: Double?
        var lastSpo2: Int?
        var lastHrv: Int?
        var lastTemp: Double?
        var battery: Int?
        var lastEvent: Date?
        var lastSync: Date?
        var sleepStart: Date?
        var sleepEnd: Date?
        var sawSleep: Bool = false
        var sleepNights: [String: SleepNight] = [:]
    }

    private static var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mellow_store.json")
    }

    func persist() {
        let p = Persisted(hr: hrHistory, temp: tempHistory, spo2: spo2History, hrv: hrvHistory,
                          lastHr: instantHrBpm, lastSpo2: spo2Percent, lastHrv: hrvRmssdMs,
                          lastTemp: skinTempC, battery: batteryPercent, lastEvent: lastEventDate,
                          lastSync: lastSyncDate, sleepStart: sleepStartDate, sleepEnd: sleepEndDate,
                          sawSleep: sawSleepFlags, sleepNights: sleepNights)
        if let data = try? JSONEncoder().encode(p) {
            try? data.write(to: Self.storeURL, options: .atomic)
        }
    }

    func loadPersisted() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        hrHistory = p.hr; tempHistory = p.temp; spo2History = p.spo2; hrvHistory = p.hrv
        instantHrBpm = p.lastHr; spo2Percent = p.lastSpo2; hrvRmssdMs = p.lastHrv
        skinTempC = p.lastTemp; batteryPercent = p.battery; lastEventDate = p.lastEvent
        lastSyncDate = p.lastSync; sleepStartDate = p.sleepStart; sleepEndDate = p.sleepEnd
        sawSleepFlags = p.sawSleep; sleepNights = p.sleepNights
    }

    func reset() {
        recordsThisSession = 0
        ppgWaveform.removeAll()
        lastPPGDate = nil
        isStreamingPPG = false
        sensorStateName = nil
        // sleep window + per-night aggregation rebuilt from the full history pull
        // each sync (cursor-0 re-sync re-sends every 0x6a period, so clear or stage
        // minutes double-count)
        inBed = nil
        sleepStartDate = nil
        sleepEndDate = nil
        sawSleepFlags = false
        sleepNights.removeAll()
        bpmEstimator.reset()
        recentBpms.removeAll()
        lastBpmComputeS = 0
        ppgBuffer.removeAll()
        lastWaveformPublishS = 0
        hrBaseline = nil
        hrRejectStreak = 0
    }

    // clear live measurement state when measuring stops (screen shows "—"/no
    // waveform not a frozen last value)
    func clearLiveHR() {
        isStreamingPPG = false
        ppgWaveform = []
        ppgBuffer.removeAll()
        recentBpms.removeAll()
        lastGoodBpmS = 0
        instantHrBpm = nil
        bpmEstimator.reset()
    }

    // throttle live-BPM recompute + UI publish (PPG arrives ~24/s; per-sample
    // re-rendered the chart 24×/s = lag). recompute at most 1/s, smooth across
    // recent estimates
    private var lastBpmComputeS: TimeInterval = 0
    private var recentBpms: [Double] = []
    // wall-clock of last ACCEPTED (clean) BPM. expires smoothing buffer after a
    // stretch of motion-corrupted windows so a fresh reading isnt blended with stale
    private var lastGoodBpmS: TimeInterval = 0

    // feed one live PPG sample from ring 0x33 stream. appends to rolling waveform,
    // recomputes smoothed instant BPM at most 1/s. NOTE: does NOT touch hrHistory
    // (that's recorded HR; raw live PPG too noisy to log there)
    private var ppgBuffer: [Double] = []
    private var lastWaveformPublishS: TimeInterval = 0

    func ingestPPG(_ sample: Double, at date: Date = Date()) {
        lastPPGDate = date
        bpmEstimator.add(sample, at: date)

        // buffer waveform, publish array only ~3×/sec. publishing @Published per-
        // sample (~24/s) re-rendered chart 24×/s and lagged. batching stays smooth
        ppgBuffer.append(sample)
        if ppgBuffer.count > maxPPG { ppgBuffer.removeFirst(ppgBuffer.count - maxPPG) }
        let now = date.timeIntervalSince1970
        if now - lastWaveformPublishS >= 0.33 {
            lastWaveformPublishS = now
            if !isStreamingPPG { isStreamingPPG = true }
            ppgWaveform = ppgBuffer
        }

        guard now - lastBpmComputeS >= 1.0 else { return }
        lastBpmComputeS = now

        // estimator returns nil when window is motion-corrupted; HOLD last clean
        // value rather than show a number tracking hand movement
        guard let bpm = bpmEstimator.estimateBPM(), bpm >= 35, bpm <= 180 else { return }

        // clean readings lapsed (sustained motion / poor contact): start smoothing fresh
        if now - lastGoodBpmS > 8 { recentBpms.removeAll() }
        lastGoodBpmS = now

        // median of last few accepted estimates kills residual jitter
        recentBpms.append(bpm)
        if recentBpms.count > 5 { recentBpms.removeFirst(recentBpms.count - 5) }
        let sorted = recentBpms.sorted()
        instantHrBpm = sorted[sorted.count / 2]
    }

    func setSensorState(_ name: String?) { sensorStateName = name }

    // back-fill real timestamps once anchor resolves. records arriving before the
    // 0x42 anchor get a receive-time estimate; this corrects them so an overnight
    // sync isnt bunched at now. resolve maps ring tick to UTC ms (nil if unresolvable)
    func reanchorTimestamps(_ resolve: (UInt32) -> UInt64?) {
        func fix(_ arr: inout [Sample]) {
            for i in arr.indices where !arr[i].timeResolved && arr[i].ringTime != 0 {
                if let utc = resolve(arr[i].ringTime) {
                    arr[i].timeMs = utc
                    arr[i].timeResolved = true
                }
            }
            arr.sort { $0.timeMs < $1.timeMs }
        }
        fix(&hrHistory); fix(&tempHistory); fix(&spo2History); fix(&hrvHistory)
        // rebuild sleep window from re-timed in-bed HR/temp coverage if needed
        if let first = (hrHistory + tempHistory).filter({ $0.timeResolved }).map(\.date).min(),
           sleepStartDate == nil || sleepStartDate! > first { /* keep flag-derived if present */ }
    }

    func ingest(_ rec: DecodedRecord) {
        recordsThisSession += 1
        let resolved = rec.eventTimeMs != nil
        let t = rec.eventTimeMs ?? rec.receivedAtMs
        let rt = rec.ringTime
        healthExport?(rec, Date(timeIntervalSince1970: Double(t) / 1000.0))

        if let hr = rec.instantHrBpm {
            // per-packet instant_hr_bpm is median of a SINGLE IBI packet, so a lone
            // noisy beat (~1.8 s -> 33 bpm) or motion artifact (~0.42 s -> 143 bpm)
            // becomes a spike. drop a point leaping > maxHrStepBpm from baseline
            // (unless start of a sustained trend) before it enters charted history
            if let clean = hrSpikeGate(hr) {
                instantHrBpm = clean
                append(&hrHistory, Sample(timeMs: t, value: clean, ringTime: rt, timeResolved: resolved))
            }
        }
        if let temp = rec.tempC {
            skinTempC = temp
            append(&tempHistory, Sample(timeMs: t, value: temp, ringTime: rt, timeResolved: resolved))
        }
        if let s = rec.spo2Percent {
            spo2Percent = s
            append(&spo2History, Sample(timeMs: t, value: Double(s), ringTime: rt, timeResolved: resolved))
        }
        if let rmssd = rec.hrvRmssdMs {
            hrvRmssdMs = rmssd
            append(&hrvHistory, Sample(timeMs: t, value: Double(rmssd), ringTime: rt, timeResolved: resolved))
        }
        if let state = rec.stateName { wearStateName = state }

        // sleep flags from ring's internal logs (0x43 debug records)
        if let d = rec.debugText, d.contains("in_bed") {
            sawSleepFlags = true
            let isInBed = d.contains("in_bed=1")
            inBed = isInBed
            if isInBed {
                let when = Date(timeIntervalSince1970: Double(t) / 1000.0)
                if sleepStartDate == nil { sleepStartDate = when }
                sleepEndDate = when
            }
        }
        if let d = rec.debugText, d.contains("check_sleep") { sawSleepFlags = true }

        // 0x6a SleepPeriodInfo -> per-night stage/breath aggregation. each record is
        // one ~30s period tagged with a stage; tally minutes/stage, count wake
        // transitions as awakenings, collect breaths
        if rec.tag == 0x6a, let state = rec.sleepState {
            ingestSleepPeriod(state: state,
                              respiratoryRate: rec.respiratoryRate,
                              avgHr: rec.sleepAvgHr,
                              atMs: t)
            sawSleepFlags = true
        }
        // 0x76 bedtime period -> night start/end window boundaries
        if rec.tag == 0x76, rec.bedtimeStartRt != nil || rec.bedtimeEndRt != nil {
            ingestBedtimeWindow(rec, atMs: t)
        }

        lastEventDate = Date(timeIntervalSince1970: Double(t) / 1000.0)

        recentRecords.insert(rec, at: 0)
        if recentRecords.count > maxRecords { recentRecords.removeLast(recentRecords.count - maxRecords) }
    }

    // local "yyyy-MM-dd" day key, matching the metrics layer grouping so a night's
    // periods land under the same key the scores use
    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar.current
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // fold one 0x6a sleep period into its night, keyed by local day of the period
    // timestamp. counts stage minutes, awakenings (asleep->wake), respiratory rates
    private func ingestSleepPeriod(state: Int, respiratoryRate: Double?, avgHr: Double?, atMs t: UInt64) {
        let date = Date(timeIntervalSince1970: Double(t) / 1000.0)
        let key = Self.dayKeyFormatter.string(from: date)
        var night = sleepNights[key] ?? SleepNight(dayKey: key)

        // window bounds from period coverage (fallback when no 0x76 boundary)
        if night.startMs == nil || t < night.startMs! { night.startMs = t }
        if night.endMs == nil || t > night.endMs! { night.endMs = t }

        switch state {
        case 0: night.deepPeriods += 1
        case 1: night.lightRemPeriods += 1
        default: night.wakePeriods += 1   // 2 (or any out-of-range) = wake
        }
        // awakening = transition from asleep into wake
        if state == 2, let last = night.lastState, last != 2 {
            night.awakenings += 1
        }
        night.lastState = state

        if let rr = respiratoryRate, rr > 0 { night.respiratoryRates.append(rr) }
        if let hr = avgHr, hr > 0 { night.sleepAvgHrSum += hr; night.sleepAvgHrCount += 1 }

        sleepNights[key] = night
    }

    // apply a 0x76 bedtime period's boundaries to the night window. ring reports
    // these in ring-time; caller resolved record UTC into t, so widen the window
    // with the resolved record time (precise per-boundary UTC needs the anchor)
    private func ingestBedtimeWindow(_ rec: DecodedRecord, atMs t: UInt64) {
        let date = Date(timeIntervalSince1970: Double(t) / 1000.0)
        let key = Self.dayKeyFormatter.string(from: date)
        var night = sleepNights[key] ?? SleepNight(dayKey: key)
        if night.startMs == nil || t < night.startMs! { night.startMs = t }
        if night.endMs == nil || t > night.endMs! { night.endMs = t }
        sleepNights[key] = night
        sawSleepFlags = true
    }

    // battery from ring 0x0d response: percent at byte[2] directly; voltage informational
    func setBattery(percent: Int, voltageMv: Int? = nil) {
        batteryPercent = min(100, max(0, percent))
        if let mv = voltageMv { batteryVoltageMv = mv }
    }

    func log(_ direction: PacketLogEntry.Direction, _ bytes: [UInt8], note: String = "") {
        let entry = PacketLogEntry(timeMs: UInt64(Date().timeIntervalSince1970 * 1000),
                                   direction: direction, hex: bytes.hexString, note: note)
        packetLog.insert(entry, at: 0)
        if packetLog.count > maxPackets { packetLog.removeLast(packetLog.count - maxPackets) }
    }

    // charted HR series: outlier-reject then bin by wall-clock
    // time into 1-min buckets (point = median of minute). binning by time not
    // sample count keeps the trend right when samples are irregularly spaced.
    // raw hrHistory unchanged for export/debug
    var hrHistorySmoothed: [Sample] {
        Self.minuteBinned(hrHistory)
    }

    // bucket into 1-min bins (median per bin) after dropping impossible bpm
    // drop 0 / <25 / >240, dont clamp
    static func minuteBinned(_ samples: [Sample], bucketMs: UInt64 = 60_000) -> [Sample] {
        let clean = samples.filter { $0.value >= 25 && $0.value <= 240 }
        guard !clean.isEmpty else { return [] }
        var bins: [UInt64: [Sample]] = [:]
        for s in clean { bins[s.timeMs / bucketMs, default: []].append(s) }
        return bins.keys.sorted().map { key in
            let group = bins[key]!
            let vals = group.map(\.value).sorted()
            let med = vals[vals.count / 2]
            // stamp bin at its midpoint for an even time axis
            return Sample(timeMs: key * bucketMs + bucketMs / 2, value: med,
                          ringTime: 0, timeResolved: true)
        }
    }

    static func rollingMedian(_ samples: [Sample], window: Int) -> [Sample] {
        guard samples.count > 2, window > 1 else { return samples }
        let half = window / 2
        return samples.indices.map { i in
            let lo = max(0, i - half)
            let hi = min(samples.count - 1, i + half)
            var vals = samples[lo...hi].map(\.value).sorted()
            let med = vals[vals.count / 2]
            var s = samples[i]
            s = Sample(id: s.id, timeMs: s.timeMs, value: med,
                       ringTime: s.ringTime, timeResolved: s.timeResolved)
            return s
        }
    }

    private func append(_ arr: inout [Sample], _ s: Sample) {
        // dedupe by timestamp: full history re-sync (cursor 0) re-sends every
        // record, else arrays balloon and double-plot. keep latest value per timeMs
        if let i = arr.firstIndex(where: { $0.timeMs == s.timeMs }) {
            arr[i] = s
        } else {
            arr.append(s)
            if arr.count > 1 && s.timeMs < arr[arr.count - 2].timeMs {
                arr.sort { $0.timeMs < $1.timeMs }
            }
        }
        if arr.count > maxHistory { arr.removeFirst(arr.count - maxHistory) }
    }
}

// MARK: - Wear detection

extension RingStore {
    // firmware states (state_change() in core) meaning NOT on finger: off-finger,
    // charging, out-of-power, hibernating. anything starting STATE_FINGER_ is worn
    private static let offFingerStates: Set<String> = [
        "STATE_NOT_IN_FINGER",
        "STATE_CHARGING_PHASE",
        "STATE_OUT_OF_POWER",
        "STATE_RING_HIBERNATE_LOW_POWER",
        "STATE_UNSPECIFIED",
    ]

    // how recent a HR/HRV sample must be to count as live data; beyond this ring is
    // off finger / charging / unsynced
    static let freshWindow: TimeInterval = 20 * 60   // 20 minutes

    // true when firmware state says on-finger. nil when no wear event seen yet, so
    // callers fall back to freshness
    var wearStateWorn: Bool? {
        guard let s = wearStateName else { return nil }
        if s.hasPrefix("STATE_FINGER") { return true }
        if Self.offFingerStates.contains(s) { return false }
        return nil
    }

    var lastBiometricDate: Date? {
        [hrHistory.last?.date, hrvHistory.last?.date, lastEventDate]
            .compactMap { $0 }.max()
    }

    var hasFreshBiometrics: Bool {
        guard let last = lastBiometricDate else { return false }
        return Date().timeIntervalSince(last) <= Self.freshWindow
    }

    // source of truth for "worn right now": firmware wear state if we have one,
    // else data freshness. gates the live Stress readout
    var isWornNow: Bool {
        if let worn = wearStateWorn { return worn && hasFreshBiometrics }
        return hasFreshBiometrics
    }
}

extension RingStore {
    static var previewPopulated: RingStore {
        let store = RingStore()
        let nowS = Date().timeIntervalSince1970
        let now = UInt64(nowS * 1000)
        func series(_ base: Double, _ amp: Double, _ n: Int, jitter: Double = 0) -> [Sample] {
            (0..<n).map { i in
                let t = now - UInt64((n - i) * 60_000)
                // deterministic spikiness on the slow wave so preview HR looks like
                // real per-minute data + exercises the chart overshoot-clipping
                let spike = jitter == 0 ? 0
                    : jitter * (sin(Double(i) * 2.3) + 0.5 * sin(Double(i) * 5.1) + 0.3 * sin(Double(i) * 11.0))
                let v = base + amp * sin(Double(i) / 4.0) + spike
                return Sample(timeMs: t, value: v, ringTime: 0, timeResolved: true)
            }
        }
        store.hrHistory = series(62, 6, 60, jitter: 7)
        store.tempHistory = series(33.5, 0.4, 40)
        store.spo2History = series(97, 1, 30)

        let step = 1800.0                          // 30 min
        let count = Int(30 * 24 * 3600 / step)     // ~1440 points
        var hrv: [Sample] = []
        var hr: [Sample] = []
        hrv.reserveCapacity(count); hr.reserveCapacity(count)
        for i in 0..<count {
            let tS = nowS - Double(count - 1 - i) * step
            let hourOfDay = (tS.truncatingRemainder(dividingBy: 86400)) / 3600  // 0-24
            // circadian: peak HRV ~4am, trough ~3pm
            let circadian = cos((hourOfDay - 4) / 24 * 2 * .pi)                 // +1 night, -1 mid-afternoon
            let dayIdx = Double(i) / (24 * 3600 / step)
            let drift = sin(dayIdx / 6.0) * 5                                   // multi-day swings
            let jitter = sin(Double(i) * 1.7) * 4 + sin(Double(i) * 0.37) * 3   // deterministic noise
            let rmssd = max(12, 46 + circadian * 16 + drift + jitter)
            hrv.append(Sample(timeMs: UInt64(tS * 1000), value: rmssd, ringTime: 0, timeResolved: true))
            let bpm = max(45, 60 - circadian * 9 - drift * 0.4 + sin(Double(i) * 0.9) * 3)
            hr.append(Sample(timeMs: UInt64(tS * 1000), value: bpm, ringTime: 0, timeResolved: true))
        }
        store.hrvHistory = hrv

        store.instantHrBpm = store.hrHistory.last?.value
        store.skinTempC = store.tempHistory.last?.value
        store.spo2Percent = 97
        store.hrvRmssdMs = Int(hrv.last?.value.rounded() ?? 48)
        store.batteryPercent = 78
        store.wearStateName = "STATE_FINGER_USER_ACTIVE"
        store.lastEventDate = Date()
        store.statusLine = "Connected"
        store.recordsThisSession = 130
        return store
    }

    static var previewNotWorn: RingStore {
        let store = previewPopulated
        let gap: TimeInterval = 5 * 3600   // took it off 5 h ago
        let cutoffMs = UInt64((Date().timeIntervalSince1970 - gap) * 1000)
        store.hrHistory = store.hrHistory.filter { $0.timeMs <= cutoffMs }
        store.hrvHistory = store.hrvHistory.filter { $0.timeMs <= cutoffMs }
        store.instantHrBpm = nil
        store.wearStateName = "STATE_NOT_IN_FINGER"
        store.lastEventDate = Date(timeIntervalSince1970: Double(cutoffMs) / 1000.0)
        store.statusLine = "Not worn"
        return store
    }
}
