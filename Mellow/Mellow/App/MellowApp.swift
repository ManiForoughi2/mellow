import SwiftUI
import Combine

@MainActor
final class AppModel: ObservableObject {
    let store: RingStore
    let session: RingSession
    let health: HealthKitBridge
    // drives claim -> provision -> handshake -> stream flow
    let connect: ConnectController
    let metrics: MetricsStore

    // age in years for HR-max/strain-zone/VO2max (Tanaka HRmax). from
    // mellow.birthDate unix ts; 0 = unset -> neutral 30 default
    private var userAge: Double {
        let ts = UserDefaults.standard.double(forKey: "mellow.birthDate")
        guard ts > 0 else { return 30 }
        let birth = Date(timeIntervalSince1970: ts)
        let years = Calendar.current.dateComponents([.year], from: birth, to: Date()).year ?? 30
        return Double(max(5, min(120, years)))
    }

    private var cancellables = Set<AnyCancellable>()

    // true only once claim is confirmed (saved key authenticated against ring at
    // least once), NOT merely when a key exists. key is saved at start of claim
    // before ring confirms it; gating on key-presence would auto-connect a dead key
    @Published var hasAuthKey: Bool

    var isConnected: Bool { connect.isConnected }

    var connectionPhase: ConnectController.Phase { connect.phase }

    init() {
        // no baked-in key: every user claims own ring via onboarding which mints a
        // fresh random key, writes it to the factory-reset ring, saves to Keychain.
        // a hardcoded key would leak in public repo and wont work for others
        #if DEBUG
        // UI-preview launch mode (Simulator/Maestro only): seed deterministic sample
        // data and pretend ring is claimed so tabs are reachable without a ring.
        // enabled via -MellowUIPreview YES
        let notWorn = UserDefaults.standard.bool(forKey: "MellowUIPreviewNotWorn")
        // either preview flag = UI-preview mode (skips cover, no BLE)
        let uiPreview = UserDefaults.standard.bool(forKey: "MellowUIPreview") || notWorn
        let s: RingStore
        if notWorn { s = RingStore.previewNotWorn }
        else if uiPreview { s = RingStore.previewPopulated }
        else { s = RingStore(); s.loadPersisted() }
        #else
        let s = RingStore()
        s.loadPersisted()
        #endif
        store = s
        let sess = RingSession(store: s)
        session = sess
        let h = HealthKitBridge()
        health = h
        let m = MetricsStore()
        m.loadPersisted()
        metrics = m
        #if DEBUG
        hasAuthKey = uiPreview ? true : AuthKeyStore.isClaimConfirmed
        #else
        hasAuthKey = AuthKeyStore.isClaimConfirmed
        #endif
        connect = ConnectController(session: sess, store: s)

        // late-bind app back-reference so saving a key can refresh hasAuthKey
        // (avoids chicken-and-egg in init)
        connect.attach(app: self)

        // recompute on sync settle. lastSyncDate flips once per completed sync, so
        // debouncing off it gives one recompute per sync not per record
        m.recompute(from: s, age: userAge)
        s.$lastSyncDate
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self, weak m, weak s] _ in
                guard let self, let m, let s else { return }
                m.recompute(from: s, age: self.userAge)
            }
            .store(in: &cancellables)

        // forward to Apple Health (no-op until authorized)
        s.healthExport = { [weak h] rec, date in
            guard let h else { return }
            if let hr = rec.instantHrBpm { h.saveHeartRate(hr, date: date) }
            if let spo2 = rec.spo2Percent { h.saveSpO2(spo2, date: date) }
            if let temp = rec.tempC { h.saveBodyTemp(temp, date: date) }
            if let hrv = rec.hrvRmssdMs { h.saveHRV(hrv, date: date) }
        }
    }

    func refreshAuthKeyState() {
        hasAuthKey = AuthKeyStore.isClaimConfirmed
        session.reloadAuthKey()
    }

    // recompute on foreground so a Settings birth-date change reflects without
    // waiting for next sync
    func recomputeMetrics() {
        metrics.recompute(from: store, age: userAge)
    }

    // idempotently (re)establish connection, called on every foreground
    func ensureConnected() {
        #if DEBUG
        if AppModel.isUIPreview { return }
        #endif
        guard hasAuthKey else { return }            // not set up yet -> onboarding handles it
        guard !connect.isConnected, !connect.isWorking else { return }  // already good/in-flight
        connect.claim()
    }

    // true in any Simulator/Maestro UI-preview launch; suppresses real BLE
    static var isUIPreview: Bool {
        UserDefaults.standard.bool(forKey: "MellowUIPreview")
            || UserDefaults.standard.bool(forKey: "MellowUIPreviewNotWorn")
    }
}

@main
struct MellowApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.store)
                .environmentObject(model.session)
                .environmentObject(model.health)
                .environmentObject(model.connect)
                .environmentObject(model.metrics)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                // re-score and re-kick connection. iOS may drop/idle the link while
                // backgrounded; nudging every foreground makes reconnect smooth
                model.recomputeMetrics()
                model.ensureConnected()
            }
        }
    }
}
