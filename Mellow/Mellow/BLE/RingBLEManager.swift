import Foundation
import CoreBluetooth
import Combine
import os

private let bleLog = Logger(subsystem: "com.maniforoughi.mellow", category: "ble")

// thin CoreBluetooth transport: scans by service UUID, connects, discovers notify
// + cmd characteristics by property (not guessed UUID), pumps notifications to a
// delegate. all protocol logic lives in RingSession; no opcodes here
final class RingBLEManager: NSObject, ObservableObject {

    enum ConnectionState: Equatable {
        case poweredOff
        case unauthorized
        case idle
        case scanning
        case connecting
        case discovering
        case ready            // notify + cmd chars found, notifications on
        case disconnected(String)
    }

    @Published private(set) var state: ConnectionState = .idle
    @Published private(set) var discoveredRSSI: Int?

    var onNotification: (([UInt8]) -> Void)?
    var onReady: (() -> Void)?
    var onDisconnect: ((String) -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var notifyChar: CBCharacteristic?
    private var cmdChar: CBCharacteristic?

    private let lastPeripheralKey = "mellow.lastPeripheralUUID"

    // fallback timer for cached-peripheral fast path: after factory reset + "forget
    // this device" the ring presents a NEW identity, so old cached UUID never
    // connects and we hang on "connecting". if cached handle doesnt reach a live
    // link quickly, discard it and fall back to a service scan
    private var cachedConnectTimeout: Task<Void, Never>?
    private static let cachedConnectTimeoutSeconds: UInt64 = 6

    // persistent connection like Oura: every disconnect re-issues connect() (never
    // times out) so link re-establishes the instant ring is reachable, incl
    // background. cleared only on intentional teardown
    private var keepConnected = false

    // deferred reconnect. failed connect schedules NEXT attempt on a future runloop
    // tick instead of re-issuing connect() synchronously - that sync path is
    // unbounded recursion (didFailToConnect -> connect -> didFailToConnect) and
    // overflows the stack when ring is unreachable
    private var reconnectWork: DispatchWorkItem?
    // consecutive immediate failures, backs retry cadence off 0.5s to 30s ceiling
    private var reconnectFailures = 0

    // connect options for reliable background reconnect/sync: wake app on
    // (re)connect, disconnect, and incoming notifications
    private var connectOptions: [String: Any] {
        var o: [String: Any] = [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
            CBConnectPeripheralOptionNotifyOnNotificationKey: true,
        ]
        // iOS 17+: OS re-establishes the link itself when ring comes back in range,
        // key to smooth reconnect after a drop or worn-idle wakeup
        if #available(iOS 17.0, *) {
            o[CBConnectPeripheralOptionEnableAutoReconnect] = true
        }
        return o
    }

    override init() {
        super.init()
        // restore identifier lets iOS relaunch us in background to finish BLE work
        // and hand back the connected peripheral (see willRestoreState)
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [
                                    CBCentralManagerOptionShowPowerAlertKey: true,
                                    CBCentralManagerOptionRestoreIdentifierKey: "com.maniforoughi.mellow.central",
                                   ])
    }

    // MARK: - Public API

    func startScan() {
        keepConnected = true
        bleLog.notice("startScan: centralState=\(String(describing: self.central.state.rawValue), privacy: .public) confirmed=\(AuthKeyStore.isClaimConfirmed) savedUUID=\(UserDefaults.standard.string(forKey: self.lastPeripheralKey) ?? "none", privacy: .public)")
        guard central.state == .poweredOn else {
            bleLog.notice("startScan: radio not powered on yet — will scan on poweredOn")
            return
        }
        // already connected (e.g. restored by iOS)? resume from there
        if let p = peripheral, p.state == .connected {
            state = .discovering
            p.discoverServices([RingGATT.serviceUUID])
            return
        }
        // first: grab a peripheral iOS ALREADY connected to our service. after
        // OS-level pairing/reinstall saved UUID can be stale but ring may still be
        // system-connected (wont advertise then, so scan never finds it).
        // retrieveConnectedPeripherals catches exactly this
        let already = central.retrieveConnectedPeripherals(withServices: [RingGATT.serviceUUID])
        if let p = already.first {
            bleLog.notice("startScan: found system-connected peripheral \(p.identifier.uuidString, privacy: .public) — connecting directly")
            UserDefaults.standard.set(p.identifier.uuidString, forKey: lastPeripheralKey)
            connect(p)   // connecting an already-connected peripheral fires didConnect immediately
            return
        }
        // steady state: connect by saved identifier WITHOUT scanning. connect()
        // never times out, stays pending and completes instant ring reachable. arm
        // short fallback so stale UUID falls back to scan
        if let idString = UserDefaults.standard.string(forKey: lastPeripheralKey),
           let uuid = UUID(uuidString: idString),
           let p = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            bleLog.notice("startScan: trying cached UUID \(idString, privacy: .public) (+parallel scan=\(AuthKeyStore.isClaimConfirmed))")
            connect(p)
            // for a ring we own leave connect() pending forever. ALSO run a parallel
            // service scan as backup: worn idle ring advertises in brief windows on
            // wake, catching that advert connects faster than the pending handle
            // alone. removes the "sometimes needs the charger" inconsistency
            if AuthKeyStore.isClaimConfirmed {
                central.scanForPeripherals(withServices: [RingGATT.serviceUUID],
                                           options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            } else {
                startCachedConnectTimeout()
            }
            return
        }
        beginServiceScan()
    }

    // discard cached-peripheral attempt and scan air for service UUID, reliable
    // path after a reset/forget
    private func beginServiceScan() {
        bleLog.notice("beginServiceScan for \(RingGATT.serviceUUID.uuidString, privacy: .public)")
        cachedConnectTimeout?.cancel()
        cachedConnectTimeout = nil
        state = .scanning
        central.scanForPeripherals(withServices: [RingGATT.serviceUUID],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    // if cached peripheral hasnt produced a live link in a few seconds, drop the
    // stale handle and scan fresh
    private func startCachedConnectTimeout() {
        cachedConnectTimeout?.cancel()
        cachedConnectTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.cachedConnectTimeoutSeconds * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            // not ready yet -> cached identity is stale, forget and scan
            if case .ready = self.state { return }
            if let p = self.peripheral { self.central.cancelPeripheralConnection(p) }
            self.peripheral = nil
            UserDefaults.standard.removeObject(forKey: self.lastPeripheralKey)
            self.beginServiceScan()
        }
    }

    func stopScan() {
        cachedConnectTimeout?.cancel()
        cachedConnectTimeout = nil
        central.stopScan()
    }

    // intentional teardown: stop maintaining connection and drop the link
    func disconnect() {
        keepConnected = false
        cachedConnectTimeout?.cancel(); cachedConnectTimeout = nil
        reconnectWork?.cancel(); reconnectWork = nil
        reconnectFailures = 0
        if let p = peripheral { central.cancelPeripheralConnection(p) }
    }

    // forget remembered peripheral so NEXT claim does a clean air scan, not chasing
    // a stale handle. on "forget ring"/reset the ring re-advertises with a NEW
    // identity so the saved UUID is dead weight that delays or blocks discovery
    func forgetSavedPeripheral() {
        bleLog.notice("forgetSavedPeripheral: clearing cached UUID")
        cachedConnectTimeout?.cancel(); cachedConnectTimeout = nil
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        UserDefaults.standard.removeObject(forKey: lastPeripheralKey)
    }

    func write(_ bytes: [UInt8]) {
        guard let p = peripheral, let c = cmdChar else { return }
        p.writeValue(Data(bytes), for: c, type: .withoutResponse)
    }

    var isReady: Bool { if case .ready = state { return true }; return false }

    // MARK: - Internal

    private func connect(_ p: CBPeripheral) {
        bleLog.notice("connect(\(p.identifier.uuidString, privacy: .public)) state=\(String(describing: p.state.rawValue), privacy: .public)")
        peripheral = p
        p.delegate = self
        state = .connecting
        central.stopScan()
        central.connect(p, options: connectOptions)
    }

    // (re)issue connect for p. ALWAYS deferred onto a later runloop tick with
    // backoff, never inline from a delegate callback (see reconnectWork). delay 0
    // still hops to next tick, enough to unwind stack between a synchronous
    // didFailToConnect and the retry
    private func reconnect(_ p: CBPeripheral, delay: TimeInterval) {
        reconnectWork?.cancel()
        peripheral = p
        p.delegate = self
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.keepConnected else { return }
            self.central.connect(p, options: self.connectOptions)
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // backoff for next retry: 0.5s doubling to 30s ceiling
    private func nextReconnectDelay() -> TimeInterval {
        reconnectFailures += 1
        return min(0.5 * pow(2, Double(reconnectFailures - 1)), 30)
    }
}

// MARK: - CBCentralManagerDelegate

extension RingBLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bleLog.notice("centralDidUpdateState: \(String(describing: central.state.rawValue), privacy: .public) keepConnected=\(self.keepConnected)")
        switch central.state {
        case .poweredOn:
            state = .idle
            // central often powers on AFTER startScan() (startup race) which hit the
            // .poweredOn guard and bailed, leaving us idle forever. (re)start now
            if keepConnected { startScan() }
        case .poweredOff:   state = .poweredOff
        case .unauthorized: state = .unauthorized
        default:            state = .idle
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        bleLog.notice("didDiscover \(peripheral.identifier.uuidString, privacy: .public) rssi=\(RSSI.intValue) name=\(peripheral.name ?? "?", privacy: .public)")
        discoveredRSSI = RSSI.intValue
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        bleLog.notice("didConnect \(peripheral.identifier.uuidString, privacy: .public) — discovering services")
        // real connect landed -> clear failure backoff so next drop retries promptly
        reconnectFailures = 0
        reconnectWork?.cancel()
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: lastPeripheralKey)
        state = .discovering
        peripheral.discoverServices([RingGATT.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        bleLog.notice("didFailToConnect \(peripheral.identifier.uuidString, privacy: .public) err=\(error?.localizedDescription ?? "nil", privacy: .public) cachedTimer=\(self.cachedConnectTimeout != nil) keepConnected=\(self.keepConnected)")
        // stale cached UUID failing -> let fallback timer scan
        if cachedConnectTimeout != nil { return }
        // re-arm pending connect on a LATER tick with backoff. re-issuing connect()
        // synchronously recurses unbounded (this callback fires again) and overflows
        if keepConnected { reconnect(peripheral, delay: nextReconnectDelay()); return }
        let reason = error?.localizedDescription ?? "connect failed"
        state = .disconnected(reason)
        onDisconnect?(reason)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        notifyChar = nil
        cmdChar = nil
        // disconnect during cached fast-path is the stale-UUID symptom; let fallback
        // timer (or its scan) take over rather than surfacing it
        if cachedConnectTimeout != nil { return }
        // persistence: re-issue connect() so link re-establishes the moment ring is
        // back in range (incl background). DONT tear down session; notify delegate to
        // show "reconnecting" not a hard failure
        if keepConnected {
            onDisconnect?("reconnecting")
            // deferred not inline: connect can fail synchronously and recurse
            reconnect(peripheral, delay: nextReconnectDelay())
            return
        }
        let reason = error?.localizedDescription ?? "disconnected"
        state = .disconnected(reason)
        onDisconnect?(reason)
    }

    // iOS relaunched us (background BLE event): recover the kept peripheral and
    // resume without re-scanning
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        keepConnected = true
        if let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let p = restored.first {
            peripheral = p
            p.delegate = self
            if p.state == .connected {
                state = .discovering
                p.discoverServices([RingGATT.serviceUUID])
            } else {
                reconnect(p, delay: 0)
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension RingBLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == RingGATT.serviceUUID }) else {
            let reason = error?.localizedDescription ?? "ring service not found"
            state = .disconnected(reason)
            onDisconnect?(reason)
            return
        }
        peripheral.discoverCharacteristics(nil, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let chars = service.characteristics else { return }

        // notify char: explicit UUID, fall back to any notify-capable char
        notifyChar = chars.first(where: { $0.uuid == RingGATT.notifyUUID })
            ?? chars.first(where: { $0.properties.contains(.notify) })

        // cmd char by property NOT guessed UUID: prefer write-without-response then
        // plain write
        cmdChar = chars.first(where: { $0.properties.contains(.writeWithoutResponse) })
            ?? chars.first(where: { $0.properties.contains(.write) })

        guard let nc = notifyChar, cmdChar != nil else {
            state = .disconnected("required characteristics missing")
            onDisconnect?("required characteristics missing")
            return
        }
        peripheral.setNotifyValue(true, for: nc)
        cachedConnectTimeout?.cancel()
        cachedConnectTimeout = nil
        state = .ready
        onReady?()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        onNotification?([UInt8](data))
    }
}
