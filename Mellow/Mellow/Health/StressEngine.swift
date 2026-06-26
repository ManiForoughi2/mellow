import Foundation

// MARK: - StressEngine

// 0-100 stress from HRV+HR off the autonomic nervous system:
// - HRV (RMSSD) primary signal: stress raises sympathetic tone, drops HRV
// - RMSSD is log-distributed, normalize on ln(RMSSD) so high values dont dominate
// - HRV varies per-person, so z-score vs person's own rolling baseline; below normal = stress
// - HR secondary: sympathetic also raises HR, folded in at lower weight, covers a missing HRV reading
// - logistic squash to 0-100: ~0-33 calm, ~34-66 moderate, ~67-100 high; keeps tails off 0/100 on noise
enum StressEngine {

    struct Point: Identifiable {
        let id = UUID()
        let date: Date
        let stress: Double  // 0-100, higher = more sympathetic
    }

    enum Band: String {
        case calm = "Calm"
        case moderate = "Moderate"
        case high = "High"

        static func of(_ stress: Double) -> Band {
            switch stress {
            case ..<34: return .calm
            case 34..<67: return .moderate
            default: return .high
            }
        }
    }

    // MARK: Weights / shape constants

    // HRV carries most signal, HR supporting
    private static let hrvWeight = 0.7
    private static let hrWeight = 0.3
    // logistic steepness; combined z of +-2 lands near band edges
    private static let logisticK = 1.1
    // below this baseline sample count the std is too noisy, fall back to population anchor
    private static let minBaseline = 8
    // healthy-adult population fallbacks when no personal baseline yet
    private static let popLnRmssd = log(40.0)
    private static let popLnRmssdSD = 0.45      // ln spread across a healthy adult's days
    private static let popHr = 65.0
    private static let popHrSD = 12.0

    // MARK: Public API

    // default 30-min buckets, one stress value each; empty if no HRV
    static func series(hrv: [RingStore.Sample],
                       hr: [RingStore.Sample],
                       bucket: TimeInterval = 1800) -> [Point] {
        guard !hrv.isEmpty else { return [] }

        // personal baseline over whole window: ln(RMSSD) and resting-HR mean/sd
        let lnRmssdAll = hrv.map { log(max($0.value, 1)) }
        let (lnMean, lnSD) = meanSD(lnRmssdAll,
                                    fallbackMean: popLnRmssd, fallbackSD: popLnRmssdSD)
        let hrVals = hr.map(\.value).filter { $0 > 25 && $0 < 230 }
        let (hrMean, hrSD) = meanSD(hrVals, fallbackMean: popHr, fallbackSD: popHrSD)

        let hrvBuckets = bucketed(hrv, bucket: bucket)
        let hrBuckets = bucketed(hr, bucket: bucket)

        return hrvBuckets.keys.sorted().map { key in
            let lnR = log(max(hrvBuckets[key]!, 1))
            // negate: below baseline = stress, so low HRV -> positive z
            let hrvZ = -(lnR - lnMean) / lnSD
            // high HR -> positive z
            var hrZ = 0.0
            if let hrv = hrBuckets[key] { hrZ = (hrv - hrMean) / hrSD }

            let combined = hrvWeight * hrvZ + (hrBuckets[key] != nil ? hrWeight * hrZ : 0)
            // re-weight to full strength when HR absent so HRV alone still spans
            let z = hrBuckets[key] != nil ? combined : (hrvZ * hrvWeight) / hrvWeight

            let stress = logistic(z)
            return Point(date: Date(timeIntervalSince1970: key * bucket + bucket / 2),
                         stress: stress)
        }
    }

    // latest bucket, for the hero readout
    static func current(hrv: [RingStore.Sample], hr: [RingStore.Sample]) -> Double? {
        series(hrv: hrv, hr: hr, bucket: 1800).last?.stress
    }

    // MARK: Math

    // logistic squash of z to 0-100, centered at 50
    private static func logistic(_ z: Double) -> Double {
        let v = 100.0 / (1.0 + exp(-logisticK * z))
        return min(100, max(0, v))
    }

    // falls back to population anchor when sample too small for a stable baseline
    private static func meanSD(_ xs: [Double],
                               fallbackMean: Double, fallbackSD: Double) -> (Double, Double) {
        guard xs.count >= minBaseline else { return (fallbackMean, fallbackSD) }
        let m = xs.reduce(0, +) / Double(xs.count)
        let varc = xs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(xs.count)
        let sd = sqrt(varc)
        // floor sd so a near-constant window doesnt collapse the z-score
        return (m, max(sd, fallbackSD * 0.5))
    }

    // mean per fixed-width bucket, keyed by floor(time / bucket)
    private static func bucketed(_ samples: [RingStore.Sample],
                                 bucket: TimeInterval) -> [Double: Double] {
        var sums: [Double: (sum: Double, n: Int)] = [:]
        for s in samples {
            let key = (Double(s.timeMs) / 1000.0 / bucket).rounded(.down)
            let prev = sums[key] ?? (0, 0)
            sums[key] = (prev.sum + s.value, prev.n + 1)
        }
        return sums.mapValues { $0.sum / Double($0.n) }
    }
}
