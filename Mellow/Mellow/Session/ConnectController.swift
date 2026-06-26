import Foundation
import Combine

// claim flow: scan -> (provision our key) -> handshake -> live stream.
// translates RingSession.Phase into a user-facing Phase.
// provisioning (provision.py / [[oura-tier2-WIN]]): factory-reset ring accepts
// arbitrary 16-byte key written as 24 10 <key> over the live link just before
// handshake. claim: generate+save key, start() opens link, on .handshaking write
// the key-set frame ahead of the proof (proof not sent until ring replies nonce,
// tens of ms later). owned ring: saved key authenticates, no provisioning.
@MainActor
final class ConnectController: ObservableObject {

    enum Phase: Equatable {
        case idle
        case scanning
        case provisioning
        case handshaking
        case streaming
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    var isWorking: Bool {
        switch phase {
        case .scanning, .provisioning, .handshaking: return true
        default: return false
        }
    }

    var isConnected: Bool { phase == .streaming }

    var failureMessage: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    private let session: RingSession
    private let store: RingStore
    // weak: AppModel owns us, avoid retain cycle. lets saving a key flip hasAuthKey
    private weak var app: AppModel?

    private var pendingProvisionKey: [UInt8]?
    private var didProvisionThisClaim = false
    // this attempt minted a new key. on fail, clear it so retry re-provisions fresh
    // rather than re-authenticating with a key the ring never received
    private var generatedKeyThisClaim = false

    private var cancellable: AnyCancellable?
    private var scanTimeout: Task<Void, Never>?

    // set by cancel() so a late .scanning/.idle from the tearing-down session
    // cant bounce UI back into scanning. cleared on next claim()
    private var userCancelled = false

    // ring only advertises when factory-reset AND on charger, so a scan timeout
    // usually means not on charger / not reset / held by another app
    private static let scanTimeoutSeconds: UInt64 = 25

    init(session: RingSession, store: RingStore) {
        self.session = session
        self.store = store
        observeSession()
    }

    // late-bind owning AppModel after AppModel.init finishes; held weak
    func attach(app: AppModel) {
        self.app = app
    }

    // reflect key/claim state into app (e.g. after Forget ring flips hasAuthKey
    // false). stands claim flow down so a lingering scan cant block onboarding intro
    func syncAuthKeyState() {
        userCancelled = true
        scanTimeout?.cancel(); scanTimeout = nil
        pendingProvisionKey = nil
        phase = .idle
        app?.refreshAuthKeyState()
    }

    // MARK: - Public control

    // begin/restart claim. mints+persists a fresh 16-byte auth key if none exists,
    // opens link, lets session drive handshake (provisioning our key first if new ring)
    func claim() {
        scanTimeout?.cancel()
        userCancelled = false
        didProvisionThisClaim = false
        pendingProvisionKey = nil
        generatedKeyThisClaim = false
        didAutoReprovision = false

        let ownedRing = AuthKeyStore.isClaimConfirmed
        if ownedRing {
            // own this ring already; connect + auth with saved key, no provisioning
            phase = .scanning
        } else {
            // not confirmed: no key, or unconfirmed key from an interrupted claim the
            // ring may never have received. either way (re-)provision over the link.
            // reuse existing unconfirmed key if present, else mint fresh.
            let key: [UInt8]
            if let existing = AuthKeyStore.load() {
                key = existing
            } else {
                key = (0..<16).map { _ in UInt8.random(in: 0...255) }
                do {
                    try AuthKeyStore.save(key)
                } catch {
                    phase = .failed("Couldn't save auth key: \(error.localizedDescription)")
                    return
                }
                generatedKeyThisClaim = true
            }
            pendingProvisionKey = key
            // session picks up the key (start() guard requires one) and arm
            // provisioning so key-set write lands before the nonce request (proven
            // enrollment order; racing a phase observer let requestNonce go first ->
            // status-1 reject)
            session.reloadAuthKey()
            session.armProvisioning(key: key)
            // dont flip hasAuthKey yet (would dismiss Connect cover mid-flow); flips
            // only at .streaming so user sees every phase
            phase = .provisioning
        }

        session.start()
        // always time out scanning. owned ring used to scan forever with no escape;
        // persistent reconnect belongs in background, not a foreground claim. on
        // timeout surface a failure with Try Again / Reset key escape
        startScanTimeout()
    }

    // abort in-flight claim and tear link down. userCancelled guard stops a trailing
    // .scanning from the tearing-down session bouncing us back
    func cancel() {
        userCancelled = true
        scanTimeout?.cancel()
        scanTimeout = nil
        pendingProvisionKey = nil
        didProvisionThisClaim = false
        session.stop()
        phase = .idle
    }

    // stop everything, return to intro WITHOUT auto-starting a claim. escape from
    // a stuck scan / failed attempt
    func startOver() {
        userCancelled = true
        scanTimeout?.cancel()
        scanTimeout = nil
        pendingProvisionKey = nil
        didProvisionThisClaim = false
        session.stop()
        phase = .idle
    }

    // discard stored key, start clean claim. for a stale key (prior claim saved a
    // key but never wrote it to a now-reset ring, so auth keeps failing). forces
    // claim() to mint fresh and provision end-to-end
    func resetAndReclaim() {
        scanTimeout?.cancel()
        scanTimeout = nil
        userCancelled = false
        session.stop()
        session.ble.forgetSavedPeripheral()   // reset ring re-advertises new identity
        AuthKeyStore.clear()
        session.reloadAuthKey()
        app?.refreshAuthKeyState()
        phase = .idle
        claim()
    }

    // MARK: - Session bridging

    private func observeSession() {
        // no scheduler hop: both @MainActor, @Published fires synchronously on
        // assignment. reacting to .handshaking same turn lands our key-set write
        // ahead of the nonce request (proven enrollment order, provision.py)
        cancellable = session.$phase
            .sink { [weak self] sessionPhase in
                self?.handle(sessionPhase)
            }
    }

    private func handle(_ sessionPhase: RingSession.Phase) {
        // user backed out: ignore trailing emissions as link tears down so we dont
        // snap back into scanning. cleared by claim()
        if userCancelled {
            if sessionPhase == .idle { phase = .idle }
            return
        }
        switch sessionPhase {
        case .idle:
            // only reflect idle if not mid-claim (claim() sets scanning before
            // start(), and start() may briefly report idle on guard fail)
            if phase != .scanning && phase != .provisioning { phase = .idle }

        case .scanning:
            // keep provisioning label if claiming a fresh ring, else just searching
            if pendingProvisionKey == nil { phase = .scanning }

        case .linkUp:
            // transitional; session moves to .handshaking immediately
            break

        case .handshaking:
            scanTimeout?.cancel()
            // provisioning is armed before start() and done by session in onLinkReady
            // ahead of the nonce request. just reflect the label here
            if pendingProvisionKey != nil {
                phase = .provisioning
            } else {
                phase = .handshaking
            }

        case .authenticated, .syncing, .steady:
            scanTimeout?.cancel()
            pendingProvisionKey = nil
            generatedKeyThisClaim = false
            phase = .streaming
            // key authenticated; confirm claim so future launches auto-connect with
            // a key we KNOW the ring accepted
            AuthKeyStore.markClaimConfirmed()
            // flip hasAuthKey so RootView dismisses Connect cover into live tabs
            app?.refreshAuthKeyState()

        case .failed(let reason):
            fail(friendlyFailure(reason))
        }
    }

    private var didAutoReprovision = false

    // on auth rejection, auto re-provision the key first: rejection means the ring
    // lost our key (factory-reset / re-onboarded to Oura), so re-write 24 10 <key> +
    // replay onboarding rather than give up. same key, reconnect once. only if that
    // also fails do we surface the error
    private func fail(_ message: String) {
        scanTimeout?.cancel()
        let lower = message.lowercased()
        // status 0x03 = ring locked to Oura. re-provisioning is futile (rejects
        // every key until factory-reset), so surface the real fix not a loop
        let lockedToOura = lower.contains("status 3") || lower.contains("locked to oura")
        let wasRejected = !lockedToOura && (lower.contains("rejected") || lower.contains("auth_key"))

        if wasRejected, !didAutoReprovision, let key = AuthKeyStore.load() {
            // auto-heal: ring was reset and lost our key. re-provision
            didAutoReprovision = true
            pendingProvisionKey = key
            session.reloadAuthKey()
            session.armProvisioning(key: key)   // writes 24 10 <key> before handshake
            phase = .provisioning
            session.start()
            return
        }

        // minted key that failed even after provisioning is bad; clear so next mints fresh
        if generatedKeyThisClaim {
            AuthKeyStore.clear()
            session.reloadAuthKey()
            generatedKeyThisClaim = false
            pendingProvisionKey = nil
            app?.refreshAuthKeyState()
        }
        phase = .failed(message)
    }

    // MARK: - Helpers

    private func startScanTimeout() {
        scanTimeout?.cancel()
        scanTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.scanTimeoutSeconds * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            // show a failure with escapes but KEEP THE SCAN RUNNING: rings advertise
            // only in brief windows, so the scan must stay alive to catch the next
            // advert. if ring shows up later the session still drives to streaming
            if self.phase == .scanning || self.phase == .provisioning {
                self.fail("Still looking for your ring. Make sure it's factory-reset and on the charger. It'll connect on its own when found, or tap Start over.")
            }
        }
    }

    private func friendlyFailure(_ reason: String) -> String {
        switch session.ble.state {
        case .poweredOff:
            return "Bluetooth is off. Turn it on to claim your ring."
        case .unauthorized:
            return "Mellow needs Bluetooth permission. Enable it in Settings."
        default:
            let lower = reason.lowercased()
            if lower.contains("pairing information") || lower.contains("peer removed") {
                return "iOS is holding a stale pairing for this ring. Go to Settings → Bluetooth, tap ⓘ next to your ring, choose Forget This Device, then try again."
            }
            if lower.contains("status 3") || lower.contains("locked to oura") {
                return "Your ring is still linked to Oura. Open the Oura app, factory-reset the ring (Settings → your ring → Reset), put it on the charger, then claim again here."
            }
            if lower.contains("rejected") || lower.contains("auth_key") {
                return "The ring rejected the key. Factory-reset it, place it on the charger, and claim again."
            }
            return reason
        }
    }
}
