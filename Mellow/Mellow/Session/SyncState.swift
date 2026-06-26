import Foundation

// persisted sync cursor + time anchor, port of persistence.SyncState (§8.1).
// _format_version 4. atomic write via tmp-file + rename
struct SyncState: Codable {
    var formatVersion: Int = 4
    var ringSerial: String = ""
    var lastSavedAtMs: UInt64 = 0
    var lastRingTimestamp: UInt32 = 0      // GetEvent cursor
    var anchorRingTime: UInt64 = 0
    var anchorUtcMs: UInt64 = 0
    var anchorFactorFlag: UInt8 = 0

    enum CodingKeys: String, CodingKey {
        case formatVersion = "_format_version"
        case ringSerial = "ring_serial"
        case lastSavedAtMs = "last_saved_at_ms"
        case lastRingTimestamp = "last_ring_timestamp"
        case anchorRingTime = "anchor_ring_time"
        case anchorUtcMs = "anchor_utc_ms"
        case anchorFactorFlag = "anchor_factor_flag"
    }

    var anchor: TimeAnchor {
        get { TimeAnchor(ringTime: anchorRingTime, utcMs: anchorUtcMs, factorFlag: anchorFactorFlag) }
        set { anchorRingTime = newValue.ringTime; anchorUtcMs = newValue.utcMs; anchorFactorFlag = newValue.factorFlag }
    }

    // advance cursor if rt newer. true if it moved
    mutating func updateCursor(_ rt: UInt32) -> Bool {
        if rt > lastRingTimestamp { lastRingTimestamp = rt; return true }
        return false
    }

    // MARK: - Persistence

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mellow-syncstate.json")
    }

    static func load() -> SyncState {
        guard let data = try? Data(contentsOf: fileURL),
              let s = try? JSONDecoder().decode(SyncState.self, from: data) else {
            return SyncState()
        }
        return s
    }

    func save() {
        var copy = self
        copy.lastSavedAtMs = UInt64(Date().timeIntervalSince1970 * 1000)
        guard let data = try? JSONEncoder().encode(copy) else { return }
        let url = Self.fileURL
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? data.write(to: url, options: .atomic)
        }
    }
}
