import Foundation

// live-HR PPG pipeline, port of hr_live.py.
// ring streams raw PPG waveform via secure-session "latest" pushes once DaytimeHR
// set to mode=Requested-subscription + subscription=Latest and left uninterrupted.
// each push carries one PPG sample whose low byte oscillates with pulse.
//
// push wire layout (Framing strips leading [0x2f, len], so offsets into OuterFrame.body):
//   body[0]=0x28  body[1]=0x02(featureID)  body[2]=status  body[3..4]=0x02,0x00
//   body[5]=0x00  body[6]=PPG_LOW  body[7]=PPG_HIGH(channel toggle, ignored)
//   body[8..11]=0x00  body[12..13]=clk(u16)  body[14]=0x7f
// use only body[6] (PPG_LOW, 0-255) as waveform, matching proven flow
enum PPGProcessor {

    // PPG "latest" push: body[0]==0x28 and body[1]==0x02 (DaytimeHR feature)
    static func isPPGPush(_ body: [UInt8]) -> Bool {
        body.count >= 9 && body[0] == 0x28 && body[1] == 0x02
    }

    // PPG waveform sample = PPG_LOW (body[6])
    static func ppgSample(from body: [UInt8]) -> Double? {
        guard isPPGPush(body) else { return nil }
        return Double(body[6])
    }

    // feature-state report: subOp 0x21, feature 0x02.
    // layout: body[0]=0x21 body[1]=featureID body[2]=mode body[3]=status body[4]=state
    static func isFeatureStateReport(_ body: [UInt8]) -> Bool {
        body.count >= 5 && body[0] == 0x21
    }

    // ring sensor state (FINGER_DETECTION=2, *_USER_ACTIVE=3+) = body[4]
    static func featureState(from body: [UInt8]) -> Int? {
        guard isFeatureStateReport(body) else { return nil }
        return Int(body[4])
    }
}

// MARK: - BPMEstimator

// rolling peak-detector: timestamped PPG samples to approx BPM. mirrors
// hr_live.py::estimate_bpm: moving-average detrend, upward zero-crossings of local
// mean with refractory window, BPM from median IBI. uses wall-clock arrival time
// for beat timing because push rate is uneven (dense ~16 Hz only during bursts)
struct BPMEstimator {

    // wall-clock arrival time (s) and 0-255 value
    private struct Point { let t: TimeInterval; let v: Double }

    private var points: [Point] = []

    // only beats inside this trailing window (s) count as recent
    let windowSeconds: TimeInterval
    // min spacing between beats (refractory), caps at ~150 bpm
    let refractorySeconds: TimeInterval
    // plausible IBI bounds (s): 0.33-2.0 s = 30-180 bpm
    let minIBI: TimeInterval
    let maxIBI: TimeInterval
    let minSamples: Int
    // motion-rejection gate: max IBI coefficient of variation (SD/mean) still trusted.
    // real pulse regular (CV ~0.03-0.12); hand movement gives erratic high-CV beats.
    // above this, return nil so UI holds last good value instead of chasing artifact
    let maxIBICoefficientOfVariation: Double

    init(windowSeconds: TimeInterval = 12,
         refractorySeconds: TimeInterval = 0.4,
         minIBI: TimeInterval = 0.33,
         maxIBI: TimeInterval = 2.0,
         minSamples: Int = 20,
         maxIBICoefficientOfVariation: Double = 0.22) {
        self.windowSeconds = windowSeconds
        self.refractorySeconds = refractorySeconds
        self.minIBI = minIBI
        self.maxIBI = maxIBI
        self.minSamples = minSamples
        self.maxIBICoefficientOfVariation = maxIBICoefficientOfVariation
    }

    // append sample, prune anything older than window
    mutating func add(_ value: Double, at date: Date) {
        let t = date.timeIntervalSince1970
        points.append(Point(t: t, v: value))
        let cutoff = t - windowSeconds
        if points.first.map({ $0.t < cutoff }) == true {
            points.removeAll { $0.t < cutoff }
        }
    }

    mutating func reset() { points.removeAll() }

    // current approx BPM, nil while warming up / between bursts
    func estimateBPM() -> Double? {
        let n = points.count
        guard n >= minSamples else { return nil }

        let ts = points.map(\.t)
        let xs = points.map(\.v)

        // moving-average detrend (window ~1/8 of buffer, >=5 samples)
        let win = max(5, n / 8)
        var detrended = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let lo = max(0, i - win)
            let hi = min(n, i + win + 1)
            var sum = 0.0
            for j in lo..<hi { sum += xs[j] }
            let base = sum / Double(hi - lo)
            detrended[i] = xs[i] - base
        }

        // require meaningful peak-to-peak swing (~18% of full P2P) so flat noise
        // between bursts doesnt manufacture phantom beats
        let p2p = (detrended.max() ?? 0) - (detrended.min() ?? 0)
        guard p2p > 0 else { return nil }
        let threshold = p2p * 0.18

        // upward zero crossings, gated by amplitude + refractory period
        var beats: [TimeInterval] = []
        var lastBeat: TimeInterval?
        for i in 1..<n where detrended[i - 1] <= 0 && detrended[i] > 0 {
            // following local max must clear threshold (prominence)
            guard localPeakAmplitude(detrended, from: i) >= threshold else { continue }
            let t = ts[i]
            if lastBeat == nil || (t - lastBeat!) >= refractorySeconds {
                beats.append(t)
                lastBeat = t
            }
        }
        guard beats.count >= 3 else { return nil }

        var ibis = (0..<(beats.count - 1)).map { beats[$0 + 1] - beats[$0] }
        ibis = ibis.filter { $0 >= minIBI && $0 <= maxIBI }
        guard ibis.count >= 3, let med = Self.median(ibis), med > 0 else { return nil }

        // motion rejection. genuine heartbeat gives evenly-spaced beats; hand
        // movement injects spurious crossings so surviving IBIs scatter. keep only
        // IBIs within ±35% of median, then require remaining set REGULAR (CV below
        // gate). else window is motion-corrupted: return nil so UI keeps last clean read
        let consistent = ibis.filter { abs($0 - med) <= 0.35 * med }
        guard consistent.count >= 3 else { return nil }
        let mean = consistent.reduce(0, +) / Double(consistent.count)
        guard mean > 0 else { return nil }
        let variance = consistent.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(consistent.count)
        let cv = variance.squareRoot() / mean
        guard cv <= maxIBICoefficientOfVariation else { return nil }

        // median of consistent beats, robust to any single straggler
        guard let cleanMed = Self.median(consistent), cleanMed > 0 else { return nil }
        return 60.0 / cleanMed
    }

    // peak amplitude of rising lobe starting at i, until it turns over
    private func localPeakAmplitude(_ d: [Double], from i: Int) -> Double {
        var peak = d[i]
        var j = i + 1
        while j < d.count, d[j] >= d[j - 1] { peak = max(peak, d[j]); j += 1 }
        return peak
    }

    static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2.0
    }
}
