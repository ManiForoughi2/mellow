import Foundation
import HealthKit

// write-only (never reads from Health); save* is a no-op when unavailable,
// not granted, or export off
@MainActor
final class HealthKitBridge: ObservableObject {

    // UserDefaults key shared with Settings toggle
    static let exportEnabledKey = "mellow.healthExport"

    private let store = HKHealthStore()

    // HealthKit never reveals read denials, so for write access treat
    // .sharingAuthorized as granted, anything else as not
    @Published private(set) var isAuthorized = false

    // persisted to UserDefaults; writes through to keep Settings in sync
    @Published var exportEnabled: Bool {
        didSet {
            guard oldValue != exportEnabled else { return }
            UserDefaults.standard.set(exportEnabled, forKey: Self.exportEnabledKey)
        }
    }

    @Published var lastError: String?

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    var isExporting: Bool { isAvailable && exportEnabled && isAuthorized }

    init() {
        // default on when unset
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.exportEnabledKey) == nil {
            exportEnabled = true
        } else {
            exportEnabled = defaults.bool(forKey: Self.exportEnabledKey)
        }
        refreshAuthorizationStatus()
    }

    // MARK: - Types

    private var heartRateType: HKQuantityType? {
        HKQuantityType.quantityType(forIdentifier: .heartRate)
    }
    private var hrvType: HKQuantityType? {
        HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)
    }
    private var spo2Type: HKQuantityType? {
        HKQuantityType.quantityType(forIdentifier: .oxygenSaturation)
    }
    private var bodyTempType: HKQuantityType? {
        HKQuantityType.quantityType(forIdentifier: .bodyTemperature)
    }

    private var writeTypes: Set<HKSampleType> {
        var s = Set<HKSampleType>()
        if let t = heartRateType { s.insert(t) }
        if let t = hrvType { s.insert(t) }
        if let t = spo2Type { s.insert(t) }
        if let t = bodyTempType { s.insert(t) }
        return s
    }

    // MARK: - Authorization

    func requestAuthorization() async {
        guard isAvailable else {
            lastError = "Apple Health isn’t available on this device."
            isAuthorized = false
            return
        }
        do {
            try await store.requestAuthorization(toShare: writeTypes, read: [])
            lastError = nil
            refreshAuthorizationStatus()
        } catch {
            lastError = error.localizedDescription
            refreshAuthorizationStatus()
        }
    }

    // iOS reports sharing status for write types (unlike reads); authorized if
    // any type is sharable
    func refreshAuthorizationStatus() {
        guard isAvailable else {
            isAuthorized = false
            return
        }
        let granted = writeTypes.contains { store.authorizationStatus(for: $0) == .sharingAuthorized }
        isAuthorized = granted
    }

    // MARK: - Saving samples

    func saveHeartRate(_ bpm: Double, date: Date) {
        guard isExporting, bpm > 20, bpm < 250, let type = heartRateType else { return }
        let unit = HKUnit.count().unitDivided(by: .minute())
        save(type: type, quantity: HKQuantity(unit: unit, doubleValue: bpm), date: date)
    }

    func saveHRV(_ rmssdMs: Int, date: Date) {
        guard isExporting, rmssdMs > 0, rmssdMs < 500, let type = hrvType else { return }
        // NOTE: ring reports RMSSD; HealthKit SDNN field is nearest store
        save(type: type,
             quantity: HKQuantity(unit: .secondUnit(with: .milli), doubleValue: Double(rmssdMs)),
             date: date)
    }

    func saveSpO2(_ percent: Int, date: Date) {
        guard isExporting, percent > 50, percent <= 100, let type = spo2Type else { return }
        // HealthKit oxygen saturation is fraction 0...1
        save(type: type,
             quantity: HKQuantity(unit: .percent(), doubleValue: Double(percent) / 100.0),
             date: date)
    }

    func saveBodyTemp(_ celsius: Double, date: Date) {
        guard isExporting, celsius > 25, celsius < 45, let type = bodyTempType else { return }
        save(type: type,
             quantity: HKQuantity(unit: .degreeCelsius(), doubleValue: celsius),
             date: date)
    }

    private func save(type: HKQuantityType, quantity: HKQuantity, date: Date) {
        let sample = HKQuantitySample(type: type, quantity: quantity, start: date, end: date)
        store.save(sample) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in self?.lastError = error.localizedDescription }
        }
    }
}
