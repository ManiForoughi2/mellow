import SwiftUI

// MARK: - HistoryScreen (real records pulled off the ring)

struct HistoryScreen: View {
    @EnvironmentObject var store: RingStore
    @EnvironmentObject var session: RingSession
    @EnvironmentObject var connect: ConnectController
    @State private var showInspector = false
    @State private var range: TrendRange = .day

    private var hasData: Bool {
        !store.tempHistory.isEmpty || !store.hrHistory.isEmpty || !store.recentRecords.isEmpty
    }

    // window the raw history to the picked range, then resample to its bucket so
    // 1D shows minute-level detail and 1M stays readable
    private func windowed(_ samples: [RingStore.Sample]) -> [RingStore.Sample] {
        let cutoff = Date().addingTimeInterval(-range.seconds)
        let inRange = samples.filter { $0.date >= cutoff }
        return RingStore.minuteBinned(inRange, bucketMs: range.bucketMs)
    }
    // live BLE link only, persisted battery survives relaunch and falsely showed "Connected"
    private var ringConnected: Bool {
        switch session.phase {
        case .authenticated, .syncing, .steady: return true
        default: return false
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: MellowTheme.Spacing.lg) {
                ringCard
                if hasData {
                    if !store.hrHistory.isEmpty || !store.tempHistory.isEmpty {
                        TrendRangePicker(range: $range)
                    }
                    if !store.hrHistory.isEmpty { hrCard }
                    if !store.tempHistory.isEmpty { tempCard }
                    recordsCard
                } else {
                    empty
                }
            }
            .padding(.horizontal, MellowTheme.Spacing.lg)
            .padding(.top, MellowTheme.Spacing.sm)
            .padding(.bottom, MellowTheme.Spacing.xxl)
        }
        .scrollIndicators(.hidden)
        .mellowScreenBackground()
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await session.resync() }
        // raw/debug tooling off the everyday screens
        .navigationDestination(isPresented: $showInspector) { DebugView() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showInspector = true } label: {
                    Image(systemName: "ladybug").foregroundColor(MellowTheme.accent)
                }
                .accessibilityLabel("Packet Inspector")
            }
        }
    }

    // MARK: Ring status (moved here from Today)

    private let grid = [GridItem(.flexible(), spacing: MellowTheme.Spacing.md),
                        GridItem(.flexible(), spacing: MellowTheme.Spacing.md)]

    private var batteryIcon: String {
        switch store.batteryPercent ?? -1 {
        case 67...: return "battery.100"
        case 34..<67: return "battery.50"
        case 0..<34: return "battery.25"
        default: return "battery.0"
        }
    }

    private var ringCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: MellowTheme.Spacing.md) {
                SectionHeader(title: "Your ring",
                              subtitle: ringConnected ? "Reading directly over Bluetooth" : "Not connected") {
                    Chip(text: ringConnected ? "LIVE" : "OFFLINE",
                         icon: ringConnected ? "dot.radiowaves.left.and.right" : "wifi.slash",
                         tint: ringConnected ? MellowTheme.good : MellowTheme.textTertiary,
                         filled: ringConnected)
                }
                LazyVGrid(columns: grid, spacing: MellowTheme.Spacing.md) {
                    StatTile(title: "Battery", value: store.batteryPercent.map { "\($0)" } ?? "—",
                             unit: store.batteryPercent != nil ? "%" : nil,
                             icon: batteryIcon, tint: MellowTheme.good)
                    StatTile(title: "Skin temp",
                             value: store.skinTempC.map { String(format: "%.1f", $0) } ?? "—",
                             unit: store.skinTempC != nil ? "°C" : nil,
                             icon: "thermometer.medium", tint: MellowTheme.temperature)
                    StatTile(title: "Records synced", value: "\(store.recordsThisSession)",
                             icon: "tray.full.fill", tint: MellowTheme.sleep)
                    StatTile(title: "Last sync",
                             value: store.lastSyncDate.map { Self.timeFormatter.string(from: $0) } ?? "—",
                             icon: "clock.arrow.circlepath", tint: MellowTheme.accent)
                }
                Text("Read straight off your ring. No account, no cloud. Pull down to re-sync.")
                    .font(.mellowLabel).foregroundColor(MellowTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; return f
    }()

    private var tempCard: some View {
        let data = windowed(store.tempHistory.filter { $0.value > 20 && $0.value < 45 })
        return TrendChartCard(title: "Temperature", subtitle: "\(range.subtitle) · skin temp",
                              samples: data, unit: "°C", color: MellowTheme.temperature,
                              valueFormat: { String(format: "%.1f", $0) },
                              showRangePicker: false, range: $range)
    }

    private var hrCard: some View {
        let data = windowed(store.hrHistory)
        return TrendChartCard(title: "Heart rate", subtitle: "\(range.subtitle) · per-minute",
                              samples: data, unit: "bpm", color: MellowTheme.heartRate,
                              valueFormat: { "\(Int($0.rounded()))" },
                              showRangePicker: false, range: $range)
    }

    private var recordsCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: MellowTheme.Spacing.sm) {
                SectionHeader(title: "Decoded records", subtitle: "\(store.recordsThisSession) synced this session")
                ForEach(Array(store.recentRecords.prefix(40).enumerated()), id: \.offset) { _, rec in
                    HStack(spacing: 10) {
                        Text(rec.tagHex)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(MellowTheme.accent)
                            .frame(width: 48, alignment: .leading)
                        Text(rec.typeName)
                            .font(.mellowCaption).foregroundColor(MellowTheme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(detail(rec))
                            .font(.mellowLabel).foregroundColor(MellowTheme.textSecondary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 5)
                    Divider().overlay(MellowTheme.stroke.opacity(0.4))
                }
            }
        }
    }

    private func detail(_ r: DecodedRecord) -> String {
        if let t = r.tempC { return String(format: "%.2f °C", t) }
        if let hr = r.instantHrBpm { return "\(Int(hr)) bpm" }
        if let s = r.spo2Percent { return "\(s)% SpO₂" }
        if let v = r.hrvRmssdMs { return "\(v) ms HRV" }
        if let st = r.stateName { return st }
        if let d = r.debugText, !d.isEmpty { return String(d.prefix(24)) }
        return ""
    }

    private var empty: some View {
        SurfaceCard {
            VStack(spacing: MellowTheme.Spacing.md) {
                Image(systemName: "tray").font(.system(size: 38, weight: .light)).foregroundColor(MellowTheme.accent)
                Text("No records yet").font(.mellowHeadline).foregroundColor(MellowTheme.textPrimary)
                Text("Pull down to download your ring's stored history over Bluetooth.")
                    .font(.mellowCaption).foregroundColor(MellowTheme.textSecondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity).padding(.vertical, MellowTheme.Spacing.lg)
        }
    }
}


