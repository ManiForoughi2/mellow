import Foundation
import Combine
import os

private let mellowLog = Logger(subsystem: "com.maniforoughi.mellow", category: "session")

// connect -> handshake -> sync lifecycle (PROTOCOL.md §6, §10). owns BLE transport,
// drives protocol state machine, feeds decoded records into RingStore. no network
@MainActor
final class RingSession: ObservableObject {

    enum Phase: Equatable {
        case idle
        case scanning
        case linkUp            // GATT ready, handshake not yet done
        case handshaking
        case authenticated     // handshake ok, data plane engaged
        case syncing
        case steady
        case failed(String)
    }

    // "Return to Oura" flow (Settings -> Forget ring): factory-reset ring, wipe
    // local key, hand back to Oura
    enum ReleaseState: Equatable {
        case idle
        case releasing
        case released
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var releaseState: ReleaseState = .idle

    let ble = RingBLEManager()
    let store: RingStore
    private var sync = SyncState.load()
    private var authKey: [UInt8]?
    private var anchor = TimeAnchor()

    private var flushCount = 0
    private var pollTask: Task<Void, Never>?

    // dedicated live-HR keep-alive. the 0x06 measurement trigger decays after
    // ~15-20s (research: DHR feature auto-reverts), so re-fire every 12s while
    // liveHRActive, decoupled from the slower 20s GetEvent cadence so the dense
    // 0x33 stream never gaps
    private var liveHRTask: Task<Void, Never>?

    // ~4 s Get-Events poll while workout/Exercise-HR active, pulling dense
    // HR/IBI/temp/steps records. separate from pollTask (20 s steady loop)
    private var workoutPollTask: Task<Void, Never>?

    // guards one-time live-HR activation writes (§6.7). DaytimeHR mode/subscription
    // pair must be sent ONCE; re-sending stalls the PPG push stream
    private var didActivateHR = false

    // live HR active. 06 04 20000000 keeps optical sensor running which DRAINS
    // battery, so OFF by default, only while user enables it. published for UI
    @Published private(set) var liveHRActive = false

    // workout/Exercise-HR path active (idempotency + drives ~4 s Get-Events poll)
    private var workoutHRActive = false

    // "Return to Oura" release requested before link up; factory-reset frame issued
    // once handshake authenticates
    private var pendingFactoryReset = false

    // link-ready handler writes this key (24 10 <key>) BEFORE the nonce request
    // (proven enrollment order, provision.py). MUST precede requestNonce or ring
    // proves against its old/empty key and rejects us (status 1). set via armProvisioning
    private var pendingProvisionKey: [UInt8]?

    init(store: RingStore) {
        self.store = store
        self.anchor = sync.anchor
        self.authKey = AuthKeyStore.load()

        ble.onReady = { [weak self] in Task { @MainActor in self?.onLinkReady() } }
        ble.onNotification = { [weak self] bytes in Task { @MainActor in self?.onNotification(bytes) } }
        ble.onDisconnect = { [weak self] reason in Task { @MainActor in self?.onDisconnect(reason) } }
    }

    // MARK: - Public control

    func reloadAuthKey() { authKey = AuthKeyStore.load() }

    func start() {
        guard authKey != nil else {
            phase = .failed("No auth_key provisioned")
            store.statusLine = "No auth_key — import one in Settings"
            return
        }
        store.reset()
        didActivateHR = false
        workoutHRActive = false
        phase = .scanning
        store.statusLine = "Scanning for ring…"
        ble.startScan()
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        workoutPollTask?.cancel()
        workoutPollTask = nil
        liveHRTask?.cancel()
        liveHRTask = nil
        liveHRActive = false
        workoutHRActive = false
        ble.disconnect()
        phase = .idle
        store.statusLine = "Stopped"
    }

    // pull-to-refresh: re-download stored history. if connected+authed, fire a
    // full-history GetEvent (cursor 0) now; else (re)start connection, which
    // auto-syncs on link-up. returns after a short settle for the refresh spinner
    func resync() async {
        if phase == .steady || phase == .authenticated || phase == .syncing {
            store.isSyncing = true
            store.statusLine = "Refreshing ring history…"
            for _ in 0..<6 {
                send(RingCommand.dataFlush, note: "resync_flush")
                send(RingCommand.getEvent(cursor: 0, maxEvents: 255), note: "resync_get")
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            store.isSyncing = false
            store.lastSyncDate = Date()
            store.persist()
            store.statusLine = "Connected — synced"
        } else {
            start()
            try? await Task.sleep(nanoseconds: 6_000_000_000)
        }
    }

    // live HR burst ("Measure Now"). dense-HR producer is the workout/Exercise-HR
    // path (RE'd from official app strength-training capture); also kicks DaytimeHR
    // PPG push as fallback waveform source. both guarded
    func requestHeartRateBurst() { startLiveHR() }

    // fire "Measure Heart Rate" (06 04 20000000) which streams dense 0x33 PPG
    // decoded in ingestLiveHR. steady poll re-fires to keep stream alive. runs
    // optical sensor continuously + DRAINS battery, on only until stopLiveHR()
    func startLiveHR() {
        guard phase == .steady || phase == .authenticated else { return }
        liveHRActive = true
        send(RingCommand.measureHeartRate, note: "measure_hr")
        store.statusLine = "Measuring — hold still"
        startLiveHRKeepAlive()
    }

    // re-fire the 0x06 trigger every 12s so the dense PPG stream doesnt decay
    private func startLiveHRKeepAlive() {
        liveHRTask?.cancel()
        liveHRTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                guard let self, self.liveHRActive, !Task.isCancelled else { break }
                self.send(RingCommand.measureHeartRate, note: "measure_hr_keepalive")
            }
        }
    }

    // stop re-firing measurement so optical sensor powers down. turns daytime-HR off too
    func stopLiveHR() {
        liveHRActive = false
        liveHRTask?.cancel()
        liveHRTask = nil
        // DaytimeHR (0x02) mode Off to power the sensor down
        send(RingCommand.setFeatureMode(feature: RingCommand.daytimeHRFeature, mode: 0x00), note: "stop_live_hr")
        store.clearLiveHR()
        if phase == .steady { store.statusLine = "Connected — synced" }
    }

    // start dense workout/Exercise-HR streaming via captured START sequence + ~4 s
    // Get-Events poll. idempotent + guarded.
    // START sequence (exact capture order):
    //   2f 03 22 03 02   Set Feature Mode: Exercise-HR (0x03) -> Requested (0x02)
    //   03 01 03         Data Collection: Exercise HR
    //   03 01 0b         Data Collection: Real Steps
    //   16 01 02         Subscribe enable
    //   18 03 18 00 10   Event subscribe: category 0x18 / flag 0x1000
    //   28 01 00         Data flush
    // records arrive as inner records on notify char (0x80 green IBI, 0x60 IBI+amp,
    // 0x46 temp, 0x47 motion, 0x7e/0x7f steps) through handleInner -> RingStore.ingest
    func activateWorkoutHR() {
        guard phase == .steady || phase == .authenticated else { return }
        guard !workoutHRActive else { return }
        workoutHRActive = true
        for cmd in RingCommand.activateWorkoutHR { send(cmd, note: "activate_workout_hr") }
        store.statusLine = "Measuring — hold still"
        startWorkoutPolling()
    }

    // stop workout/Exercise-HR: send 2f 03 22 03 00 (Exercise-HR mode Off) and
    // cancel the ~4 s poll. idempotent
    func stopWorkoutHR() {
        guard workoutHRActive else { return }
        workoutHRActive = false
        workoutPollTask?.cancel()
        workoutPollTask = nil
        send(RingCommand.stopWorkoutHR, note: "stop_workout_hr")
    }

    // provision a factory-reset ring with our 16-byte auth_key by writing the
    // enrollment key-set frame 24 10 <key> (provision.py). requires active link.
    // unused by live UI
    func provision(key: [UInt8]) {
        guard key.count == 16 else {
            store.statusLine = "Provision failed: key must be 16 bytes"
            return
        }
        send(RingCommand.keySet(key), note: "key_set")
        store.statusLine = "Provisioning key written"
    }

    // release ring back to Oura. writes factory-reset frame 1a 00, ring wipes its
    // stored auth_key and reboots blank so Oura can reclaim it (ring replies
    // 1b <status>, see handleOuter). if link not up, connect+auth first then send
    // reset. clears local key + tears down; user finishes via "Forget This Device"
    // in iOS Bluetooth settings (cant unbond in-app)
    func factoryReset() {
        guard releaseState != .releasing else { return }

        switch phase {
        case .authenticated, .syncing, .steady:
            // connected: tell ring to wipe its copy of our key before we drop
            releaseState = .releasing
            store.statusLine = "Releasing ring…"
            sendFactoryResetNow()
        default:
            // not connected (offline / stuck scanning). waiting for a handshake to
            // send the reset frame hangs forever if ring unreachable. forgetting is
            // a LOCAL action: wipe key, drop link, back to onboarding. ring claimed-
            // state is cleared separately via Oura app reset; dont block on reaching it
            pendingFactoryReset = false
            completeRelease()
        }
    }

    private func sendFactoryResetNow() {
        pendingFactoryReset = false
        send(RingCommand.factoryReset, note: "factory_reset")
        completeRelease()
    }

    // tear down after reset: invalidate local key (ring wiped its copy), stop
    // polling, drop link, clear ring-derived state
    private func completeRelease() {
        AuthKeyStore.clear()
        authKey = nil
        pollTask?.cancel()
        pollTask = nil
        workoutPollTask?.cancel()
        workoutPollTask = nil
        liveHRTask?.cancel()
        liveHRTask = nil
        liveHRActive = false
        workoutHRActive = false
        didActivateHR = false
        store.isStreamingPPG = false
        store.isSyncing = false
        ble.disconnect()
        ble.forgetSavedPeripheral()   // drop the stale UUID so re-claim scans fresh
        phase = .idle
        releaseState = .released
        store.statusLine = "Ring released — finish in Bluetooth settings"
    }

    // MARK: - Lifecycle handlers

    private func onLinkReady() {
        mellowLog.notice("onLinkReady — link up, starting handshake (provision=\(self.pendingProvisionKey != nil))")
        phase = .handshaking
        store.statusLine = "Link up — authenticating…"

        if let key = pendingProvisionKey {
            // claiming a (possibly fresh) ring: replay the proven enrollment order
            // (provision.py). order matters: event-subscribe primes the ring, key-set
            // installs our key, BOTH must precede request_nonce or ring proves against
            // its old/empty key and rejects us (status 1).
            //   08 03 00 00 00   time_or_id_req
            //   18 03 08 00 10   event_subscribe (primes enrollment)
            //   24 10 <key>      key_set
            //   2f 02 01 00      sec_cfg_pre
            //   2f 02 01 01      sec_cfg_neg
            //   2f 01 2b         request_nonce
            pendingProvisionKey = nil
            send(RingCommand.timeOrIdReq, note: "time_or_id_req")
            send(RingCommand.eventSubscribe(category: 0x08, flag: 0x1000), note: "enroll_event_sub")
            provision(key: key)
            send(RingCommand.secCfgPre, note: "sec_cfg_pre")
            send(RingCommand.secCfgNeg, note: "sec_cfg_neg")
            send(RingCommand.requestNonce, note: "request_nonce")
        } else {
            // reconnect to a ring we own: standard handshake (§6.1 steps 1-10).
            // ring replies async; proof sent when nonce notification arrives
            send(RingCommand.timeOrIdReq, note: "time_or_id_req")
            send(RingCommand.secCfgPre, note: "sec_cfg_pre")
            send(RingCommand.secCfgNeg, note: "sec_cfg_neg")
            send(RingCommand.requestNonce, note: "request_nonce")
        }
    }

    // arm provisioning for next start(): link-ready handler writes this key before
    // the handshake. call when claiming a (possibly fresh) ring
    func armProvisioning(key: [UInt8]) { pendingProvisionKey = key }

    private func onDisconnect(_ reason: String) {
        mellowLog.notice("onDisconnect: \(reason, privacy: .public) (phase=\(String(describing: self.phase), privacy: .public))")
        pollTask?.cancel()
        pollTask = nil
        workoutPollTask?.cancel()
        workoutPollTask = nil
        liveHRTask?.cancel()
        liveHRTask = nil
        workoutHRActive = false
        didActivateHR = false
        // clear live-HR on any drop: else it survives and keep-alive re-fires
        // Measure-HR on reconnect, draining the ring unasked
        liveHRActive = false
        store.isStreamingPPG = false
        // release in progress drives its own state; reset reboots ring so this
        // disconnect is expected, not a failure
        if releaseState == .released { return }
        if pendingFactoryReset {
            pendingFactoryReset = false
            releaseState = .failed(reason)
            phase = .failed(reason)
            store.statusLine = "Couldn't reach ring to release: \(reason)"
            store.isSyncing = false
            return
        }
        // persistent-connection model: a transient drop is NOT a failure, BLE layer
        // re-arms connect() and re-establishes. keep session/phase intact, show
        // "Reconnecting…" so tabs stay populated from persisted data
        if reason == "reconnecting" {
            store.statusLine = "Reconnecting…"
            store.isSyncing = false
            return
        }
        if case .failed = phase { return }
        phase = .failed(reason)
        store.statusLine = "Disconnected: \(reason)"
        store.isSyncing = false
    }

    // MARK: - Notification routing

    private func onNotification(_ value: [UInt8]) {
        store.log(.rx, value)
        // live-HR dense PPG record (0x33). format: 33 0e 32 <seq> then 6× int16 LE
        // PPG samples. feed strongest-pulsatility sample into live waveform/BPM
        if value.first == 0x33, value.count >= 16 {
            ingestLiveHR(value)
            return
        }
        // SpO2: ring sends raw red/IR PPG as 0x6e sub-records, NOT a finished %.
        // pair red/IR and compute via ratio-of-ratios, reflectance-calibrated
        ingestSpo2(from: value)
        if Framing.looksLikeOuterFrame(value) {
            for frame in Framing.parseOuterFrames(value) { handleOuter(frame) }
        } else {
            let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
            for decoded in RecordDecoder.decodeNotification(value, receivedAtMs: nowMs) {
                handleInner(decoded, nowMs: nowMs)
            }
        }
    }

    // decode 0x33 Live-HR record (6× int16 LE PPG samples after 33 0e 32 seq) and
    // push pulsatile channel into store PPG waveform + BPM estimator
    private func ingestLiveHR(_ v: [UInt8]) {
        let body = Array(v[4..<16])
        var samples = [Int16]()
        var k = 0
        while k + 1 < body.count {
            samples.append(Int16(bitPattern: UInt16(body[k]) | (UInt16(body[k + 1]) << 8)))
            k += 2
        }
        // channels are 2 LED sets × 3; index 5 had strongest pulsatility in capture
        guard samples.count >= 6 else { return }
        let ppg = Double(samples[5])
        store.ingestPPG(ppg, at: Date())
    }

    // MARK: - SpO2 (ratio-of-ratios on raw red/IR PPG)

    // most recent red/IR 0x6e sub-record awaiting its pair partner
    private var pendingSpo2Sub: (channelHi: UInt8, samples: [Double])?
    // rolling window of recent SpO2 estimates for a stable displayed value
    private var spo2Window: [Double] = []

    // scan notification for 0x6e SpO2 sub-records, pair red(0x4x)/IR(0xax-0xbx),
    // compute via ratio-of-ratios. sub-record: 6e <len=0x11> <rt:4> <header:1>
    // <12 PPG bytes>, embedded in a concatenated tag/len inner stream
    private func ingestSpo2(from value: [UInt8]) {
        var j = 0
        while j + 2 <= value.count {
            let tag = value[j]; let len = Int(value[j + 1])
            if len == 0 || j + 2 + len > value.count { break }
            let body = Array(value[(j + 2)..<(j + 2 + len)])
            if tag == 0x6e, len == 0x11 {
                let header = body[4]
                let samples = body[5..<17].map(Double.init)        // 12 PPG samples
                handleSpo2Sub(channelHi: header >> 4, samples: samples)
            } else if tag == 0x72, len == 0x10 {
                // SleepAcmPeriod: <rt:4><6 u16 metrics>. col3 (bytes 10..12) =
                // respiratory rate raw (×0.667 ≈ breaths/min); clean rows have high
                // byte == 0. gate to a physiological band
                if body.count >= 12, body[11] == 0 {
                    let raw = Int(body[10])
                    if raw >= 12, raw <= 40 {
                        store.respiratoryRate = Double(raw) * 0.667
                    }
                }
            }
            j += 2 + len
        }
    }

    private func handleSpo2Sub(channelHi: UInt8, samples: [Double]) {
        let isRed = channelHi == 0x4
        let isIR = channelHi == 0xa || channelHi == 0xb
        guard isRed || isIR else { return }

        guard let prev = pendingSpo2Sub else {
            pendingSpo2Sub = (channelHi, samples); return
        }
        // candidate pair if the two are different channels
        let prevIsRed = prev.channelHi == 0x4
        if prevIsRed != isRed {
            let red = prevIsRed ? prev.samples : samples
            let ir  = prevIsRed ? samples : prev.samples
            pendingSpo2Sub = nil
            if let spo2 = Self.spo2(red: red, ir: ir) {
                spo2Window.append(spo2)
                if spo2Window.count > 12 { spo2Window.removeFirst(spo2Window.count - 12) }
                let sorted = spo2Window.sorted()
                store.spo2Percent = Int(sorted[sorted.count / 2].rounded())  // smoothed median
            }
        } else {
            pendingSpo2Sub = (channelHi, samples)   // same channel again; replace
        }
    }

    // ratio-of-ratios SpO2 from one red/IR window. AC = peak-to-peak, DC = mean;
    // R = (AC_r/DC_r)/(AC_i/DC_i); SpO2 = 110 − 12·R (reflectance-calibrated so
    // resting lands ~95%). nil for low-perfusion/noise
    static func spo2(red: [Double], ir: [Double]) -> Double? {
        guard let rMax = red.max(), let rMin = red.min(),
              let iMax = ir.max(), let iMin = ir.min() else { return nil }
        let dcR = red.reduce(0, +) / Double(red.count)
        let dcI = ir.reduce(0, +) / Double(ir.count)
        let acR = rMax - rMin, acI = iMax - iMin
        guard dcR > 0, dcI > 0, acI > 0 else { return nil }
        let r = (acR / dcR) / (acI / dcI)
        let spo2 = 110.0 - 12.0 * r
        guard spo2 >= 70, spo2 <= 100 else { return nil }   // reject implausible
        return spo2
    }

    private func handleOuter(_ frame: Framing.OuterFrame) {
        switch frame.opcode {
        case 0x2f: // secure_session, multiplexed by body[0]
            guard let sub = frame.subOp else { return }
            switch sub {
            case 0x2c: // nonce response: body = [2c, nonce(15)]
                let nonce = Array(frame.body.dropFirst())
                handleNonce(nonce)
            case 0x2e: // handshake completion: body = [2e, status]
                let status = frame.body.count >= 2 ? frame.body[1] : 0xff
                handleHandshakeStatus(status)
            case 0x28: // live PPG "latest" push (DaytimeHR streaming)
                if let sample = PPGProcessor.ppgSample(from: frame.body) {
                    store.ingestPPG(sample, at: Date())
                }
            case 0x21: // feature-state report (sensor state for DaytimeHR)
                if let state = PPGProcessor.featureState(from: frame.body) {
                    store.setSensorState(RingEventType.stateChangeName(state))
                }
            default:
                break
            }
        case 0x0d: // battery resp. frame: 0d <len> <pct> <pct2> 00 00 <mv_lo> <mv_hi>
            // byte[2] = battery percent directly (0x64 = 100%); raw[6..8] = cell mV
            if frame.raw.count >= 3 {
                let pct = Int(frame.raw[2])
                let mv = frame.raw.count >= 8 ? (Int(frame.raw[6]) | (Int(frame.raw[7]) << 8)) : nil
                store.setBattery(percent: pct, voltageMv: mv)
            }
        case 0x1b: // factory_reset_resp, status u16 LE at raw[2..4] (0 = ok)
            let status = frame.raw.count >= 4 ? Int(frame.raw[2]) | (Int(frame.raw[3]) << 8) : -1
            if status == 0 {
                store.statusLine = "Ring released — finish in Bluetooth settings"
            } else {
                releaseState = .failed("Factory reset rejected (status \(status))")
                store.statusLine = "Factory reset rejected (status \(status))"
            }
        case 0x11: // history_fetch_resp, informational (cursor comes from records)
            break
        case 0x13: // time_sync_resp, informational
            break
        default:
            break
        }
    }

    private func handleNonce(_ nonce: [UInt8]) {
        guard let key = authKey else { return }
        guard nonce.count == 15 else { return }
        do {
            let proof = try RingCrypto.handshakeProof(authKey: key, nonce: nonce)
            send(RingCommand.submitProof(proof), note: "submit_proof")
        } catch {
            phase = .failed("Handshake: \(error.localizedDescription)")
            store.statusLine = phase.description
        }
    }

    private func handleHandshakeStatus(_ status: UInt8) {
        mellowLog.notice("handshake status = 0x\(String(format: "%02x", status), privacy: .public)")
        guard status == 0x00 else {
            // status 0x03 = STATE rejection not wrong key: ring is Oura-claimed /
            // non-enrollment (touched official app), refuses every handshake until
            // factory-reset back to enrollment. status 0x01 = wrong-key proof
            // mismatch. different fixes, see [[oura-status03-claimed-state]]
            let reason = status == 0x03
                ? "Ring is locked to Oura (status 3) — factory-reset it in the Oura app, then claim again"
                : "Auth rejected (status \(status)) — wrong auth_key?"
            phase = .failed(reason)
            store.statusLine = phase.description
            if pendingFactoryReset {
                pendingFactoryReset = false
                releaseState = .failed(reason)
            }
            return
        }
        phase = .authenticated
        // release requested while disconnected: issue factory reset now instead of
        // engaging data plane; ring is about to wipe+reboot
        if pendingFactoryReset {
            store.statusLine = "Authenticated — releasing ring…"
            sendFactoryResetNow()
            return
        }
        store.statusLine = "Authenticated — engaging data plane"
        engageDataPlaneAndSync()
    }

    // MARK: - Data plane

    private func engageDataPlaneAndSync() {
        // replay official app post-key-set feature-enable sequence so ring tracks
        // HR/sleep like an onboarded device (captured 2026-06-16; ring accepts on our key)
        for cmd in RingCommand.onboardingSequence { send(cmd, note: "onboard") }

        // §6.1 steps 12-16
        send(RingCommand.subscribeEnable, note: "subscribe_enable")
        send(RingCommand.stateCmd, note: "state_cmd")
        send(RingCommand.batteryReq, note: "battery_req")
        for cmd in RingCommand.capabilityDance { send(cmd, note: "cap_dance") }

        // per-category event subscriptions the live PPG push relies on (§6.7 /
        // hr_live.py). once, after the capability dance
        for c in RingCommand.liveFeatureCategories {
            send(RingCommand.eventSubscribe(category: c.cat, flag: c.flag), note: "live_feature_sub")
        }

        send(RingCommand.dataFlush, note: "data_flush")

        // time sync (refreshes ring RTC; elicits a 0x42 anchor shortly)
        let nowS = Int(Date().timeIntervalSince1970)
        send(RingCommand.timeSync(unixSeconds: nowS), note: "time_sync")

        // §6.1 step 17 initial GetEvent. pull from cursor 0 (FULL stored history)
        // every connect, not the saved delta cursor. ring is store-and-forward:
        // records HR/temp/SpO2/sleep to flash, we backfill on connect. full pull
        // grabs the whole night a delta cursor would miss if it advanced past it
        phase = .syncing
        store.isSyncing = true
        store.statusLine = "Downloading ring history…"
        send(RingCommand.getEvent(cursor: 0, maxEvents: 255), note: "get_event_full")

        // §6.1 step 19 ack-fetch shortly after, then steady polling
        startSteadyPolling()
    }

    // start live PPG push by sending DaytimeHR mode + subscription pair once
    // (§6.7 / hr_live.py). guarded by didActivateHR; re-sending stalls the stream
    private func activateLiveHeartRateOnce() {
        guard !didActivateHR else { return }
        didActivateHR = true
        for cmd in RingCommand.activateDaytimeHR { send(cmd, note: "activate_hr") }
        store.statusLine = "Measuring — hold still"
    }

    private func startSteadyPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // first ack-fetch ~150ms after the data burst
            try? await Task.sleep(nanoseconds: 150_000_000)
            self.send(RingCommand.getEvent(cursor: 0, maxEvents: 0), note: "ack_fetch")

            // full-drain backfill: stored night spans many pages, so pull from
            // cursor 0 several times (flush + GetEvent) before steady polling so an
            // overnight sleep recorded while disconnected fully lands
            for _ in 0..<8 {
                self.send(RingCommand.dataFlush, note: "backfill_flush")
                self.send(RingCommand.getEvent(cursor: 0, maxEvents: 255), note: "backfill_get")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { break }
            }
            self.sync.save()
            if self.phase == .syncing { self.phase = .steady; self.store.isSyncing = false; self.store.lastSyncDate = Date() }
            self.store.persist()
            self.store.statusLine = "Connected — synced"

            // NOTE: live HR OFF by default to save battery (runs optical sensor
            // continuously). user enables via Heart screen (startLiveHR); loop below
            // re-fires only while liveHRActive

            // steady: every 20 s flush + GetEvent; every 3rd cycle toggle subscribe (§10 step 12)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                if Task.isCancelled { break }
                self.flushCount += 1
                if self.flushCount % 3 == 0 {
                    self.send(RingCommand.subscribeDisable, note: "subscribe_toggle_off")
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    self.send(RingCommand.subscribeEnable, note: "subscribe_toggle_on")
                }
                self.send(RingCommand.dataFlush, note: "data_flush")
                self.send(RingCommand.getEvent(cursor: self.sync.lastRingTimestamp, maxEvents: 255), note: "get_event")
                try? await Task.sleep(nanoseconds: 200_000_000)
                self.send(RingCommand.getEvent(cursor: self.sync.lastRingTimestamp, maxEvents: 0), note: "ack_fetch")
                // live-HR re-trigger handled by the dedicated 12s keep-alive task
                self.sync.save()
                self.store.lastSyncDate = Date()
                self.store.persist()
            }
        }
    }

    // poll Get-Events every ~4 s while workout/Exercise-HR active (as official app
    // does during a logged workout) to pull dense HR records. frame 10 09
    // <startTs:4 LE> ff ff ff ff ff (RingCommand.getEvents(since:)). inner records
    // routed via onNotification -> handleInner -> RingStore.ingest
    private func startWorkoutPolling() {
        workoutPollTask?.cancel()
        workoutPollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.workoutHRActive {
                self.send(RingCommand.getEvents(since: self.sync.lastRingTimestamp), note: "workout_get_events")
                self.sync.save()
                self.store.lastSyncDate = Date()
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }

    // MARK: - Inner record handling

    private func handleInner(_ decoded: DecodedRecord, nowMs: UInt64) {
        // skip misparse-shaped records (§9.3 rule 1)
        if decoded.ringTime >= 0x8000_0000 { return }

        var decoded = decoded
        let trustworthy = !RingEventType.isStructurallyUnknown(decoded.tag)

        // anchor maintenance (§7.3)
        if decoded.tag == 0x42, let ts = decoded.timeSync {
            if let newAnchor = TimeResolver.anchorFromTimeSync(ringTime: ts.ringTime,
                                                               ringUnixApproxS: ts.ringUnixApproxS,
                                                               token: ts.token,
                                                               nowMs: nowMs) {
                anchor = newAnchor
                sync.anchor = newAnchor
                // back-fill records that arrived before this anchor so an overnight
                // sync gets real timestamps not bunched at sync-time
                store.reanchorTimestamps { TimeResolver.toUtcMs($0, anchor: newAnchor) }
            }
        } else if decoded.tag == 0x41, UInt64(decoded.ringTime) < anchor.ringTime {
            anchor = TimeAnchor()      // invalidate on ring restart regression
            sync.anchor = anchor
        }

        // interpolate event time only for trustworthy types (§9.3 rule 2)
        if trustworthy {
            decoded.eventTimeMs = TimeResolver.toUtcMs(decoded.ringTime, anchor: anchor)
            _ = sync.updateCursor(decoded.ringTime)
        }

        store.ingest(decoded)
    }

    // MARK: - TX helper

    private func send(_ bytes: [UInt8], note: String) {
        store.log(.tx, bytes, note: note)
        ble.write(bytes)
    }
}

extension RingSession.Phase {
    var description: String {
        switch self {
        case .idle: return "Idle"
        case .scanning: return "Scanning"
        case .linkUp: return "Link up"
        case .handshaking: return "Authenticating"
        case .authenticated: return "Authenticated"
        case .syncing: return "Syncing"
        case .steady: return "Connected"
        case .failed(let r): return "Failed: \(r)"
        }
    }
}
