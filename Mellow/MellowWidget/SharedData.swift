import Foundation

// reads last-known values from App Group UserDefaults so it renders while app suspended
struct MellowSnapshot {
    var recovery: Int           // 0...100
    var hr: Int                 // bpm
    var date: Date
    var isPlaceholder: Bool     // true = demo values, no app data yet

    static let demo = MellowSnapshot(recovery: 85, hr: 62, date: Date(), isPlaceholder: true)
}

// app writes recovery (Int), hr (Int), optional lastUpdated (timeIntervalSince1970 Double) here
enum MellowSharedStore {
    // must match App Group capability on both app and widget targets
    static let suiteName = "group.com.maniforoughi.mellow"

    enum Keys {
        static let recovery = "recovery"
        static let hr = "hr"
        static let lastUpdated = "lastUpdated"
    }

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    // falls back to demo when app hasnt published yet
    static func load() -> MellowSnapshot {
        guard let defaults,
              defaults.object(forKey: Keys.recovery) != nil ||
              defaults.object(forKey: Keys.hr) != nil else {
            return .demo
        }

        let recovery = defaults.object(forKey: Keys.recovery) != nil
            ? defaults.integer(forKey: Keys.recovery)
            : MellowSnapshot.demo.recovery
        let hr = defaults.object(forKey: Keys.hr) != nil
            ? defaults.integer(forKey: Keys.hr)
            : MellowSnapshot.demo.hr

        let updated: Date
        let ts = defaults.double(forKey: Keys.lastUpdated)
        updated = ts > 0 ? Date(timeIntervalSince1970: ts) : Date()

        return MellowSnapshot(recovery: clampPercent(recovery),
                             hr: max(0, hr),
                             date: updated,
                             isPlaceholder: false)
    }

    static func save(recovery: Int, hr: Int, date: Date = Date()) {
        guard let defaults else { return }
        defaults.set(clampPercent(recovery), forKey: Keys.recovery)
        defaults.set(max(0, hr), forKey: Keys.hr)
        defaults.set(date.timeIntervalSince1970, forKey: Keys.lastUpdated)
    }

    private static func clampPercent(_ v: Int) -> Int { min(100, max(0, v)) }
}
