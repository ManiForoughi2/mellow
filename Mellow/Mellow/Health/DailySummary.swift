import Foundation

// every metric optional; partial-data day still produces a row
struct DailySummary: Codable, Identifiable {
    // day key, "yyyy-MM-dd" local tz
    var id: String
    var date: Date

    var restingHR: Double?
    var hrvRMSSD: Double?
    var respiratoryRate: Double?
    var skinTempC: Double?

    var recovery: Double?       // 0–100
    var strain: Double?         // 0–21
    var sleepScore: Double?     // 0–100
    var totalSleepMin: Double?
    var vo2max: Double?

    var recoveryDetail: RecoveryResult?
    var sleepDetail: SleepScoreResult?
}
