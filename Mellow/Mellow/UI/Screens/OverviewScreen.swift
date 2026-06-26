import SwiftUI
import Charts

// MARK: - OverviewScreen (Today dashboard)

// no Recovery/Strain/Sleep scores: not real on a self-provisioned ring yet
// (no full night logged), so show only what the ring genuinely reports
struct OverviewScreen: View {
    @EnvironmentObject var store: RingStore
    @EnvironmentObject var session: RingSession
    @EnvironmentObject var connect: ConnectController
    @EnvironmentObject var metrics: MetricsStore

    // MARK: Derived data

    private var today: DailySummary? { metrics.today }

    // live BLE link only, persisted batteryPercent survives relaunch and falsely showed "Connected"
    private var ringConnected: Bool {
        switch session.phase {
        case .authenticated, .syncing, .steady: return true
        default: return false
        }
    }
    private var connectionLabel: String {
        if store.isSyncing { return "Syncing" }
        if ringConnected { return "Connected" }
        if connect.isWorking { return "Connecting" }
        return "Offline"
    }
    private var connectionTint: Color {
        if ringConnected { return MellowTheme.good }
        if connect.isWorking { return MellowTheme.accent }
        return MellowTheme.textTertiary
    }

    private var currentHR: Int? {
        store.instantHrBpm.map { Int($0.rounded()) }
            ?? store.hrHistory.last.map { Int($0.value.rounded()) }
    }
    private var restingHR: Int? { today?.restingHR.map { Int($0.rounded()) } }

    private var hasAnyData: Bool {
        currentHR != nil || store.skinTempC != nil || !store.hrHistory.isEmpty
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(spacing: MellowTheme.Spacing.lg) {
                header
                if let hr = currentHR { liveHRCard(hr) }
                if hasAnyData { measurementsGrid }
                lastNightCard
                if store.tempHistory.count >= 4 { tempChartCard }
                if !hasAnyData { emptyState }
            }
            .padding(.horizontal, MellowTheme.Spacing.lg)
            .padding(.top, MellowTheme.Spacing.sm)
            .padding(.bottom, MellowTheme.Spacing.xxl)
        }
        .scrollIndicators(.hidden)
        .mellowScreenBackground()
        .refreshable { await session.resync() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(greeting).font(.mellowTitle).foregroundColor(MellowTheme.textPrimary)
                Text(Self.dateFormatter.string(from: Date()))
                    .font(.mellowCaption).foregroundColor(MellowTheme.textTertiary)
            }
            Spacer(minLength: 8)
            Chip(text: connectionLabel,
                 icon: ringConnected || connect.isWorking ? "dot.radiowaves.left.and.right" : "wifi.slash",
                 tint: connectionTint, filled: ringConnected)
        }
        .padding(.top, MellowTheme.Spacing.sm)
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Good night"
        }
    }

    // MARK: Live HR

    private func liveHRCard(_ hr: Int) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: MellowTheme.Spacing.md) {
                SectionHeader(title: "Heart rate",
                              subtitle: store.lastEventDate.map { "as of " + Self.timeFormatter.string(from: $0) }) {
                    Chip(text: store.instantHrBpm != nil ? "LIVE" : "LATEST",
                         icon: "heart.fill", tint: MellowTheme.heartRate, filled: store.instantHrBpm != nil)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(hr)").font(.mellowDisplay(46)).foregroundColor(MellowTheme.textPrimary)
                        .contentTransition(.numericText())
                    Text("bpm").font(.mellowBody).foregroundColor(MellowTheme.textSecondary)
                    Spacer()
                    if !store.hrHistory.isEmpty {
                        MiniSparkline(samples: Array(store.hrHistorySmoothed.suffix(48).map(\.value)),
                                      tint: MellowTheme.heartRate).frame(width: 130, height: 50)
                    }
                }
            }
        }
    }

    // MARK: Measurements grid

    private let grid = [GridItem(.flexible(), spacing: MellowTheme.Spacing.md),
                        GridItem(.flexible(), spacing: MellowTheme.Spacing.md)]

    private var hrvValue: Double? { today?.hrvRMSSD ?? store.hrvRmssdMs.map(Double.init) }

    // tile only appears once value available, no "—" placeholders for
    // undecodable readings (respiratory, VO₂max, steps)
    private var measurementsGrid: some View {
        VStack(alignment: .leading, spacing: MellowTheme.Spacing.md) {
            SectionHeader(title: "Today's readings")
            LazyVGrid(columns: grid, spacing: MellowTheme.Spacing.md) {
                if let rhr = restingHR {
                    StatTile(title: "Resting HR", value: "\(rhr)", unit: "bpm",
                             icon: "heart.fill", tint: MellowTheme.heartRate)
                }
                if let hrv = hrvValue {
                    StatTile(title: "HRV", value: "\(Int(hrv.rounded()))", unit: "ms",
                             icon: "waveform.path.ecg", tint: MellowTheme.hrv)
                }
                if let spo2 = store.spo2Percent {
                    StatTile(title: "SpO₂", value: "\(spo2)", unit: "%",
                             icon: "drop.fill", tint: MellowTheme.spo2)
                }
                if let temp = store.skinTempC {
                    StatTile(title: "Skin temp", value: String(format: "%.1f", temp), unit: "°C",
                             icon: "thermometer.medium", tint: MellowTheme.temperature)
                }
            }
        }
    }

    // MARK: Last night (sleep stages from 0x6a)

    private var lastNight: RingStore.SleepNight? {
        store.sleepNights.values
            .filter { $0.asleepMin > 0 || $0.inBedMin > 0 }
            .max { ($0.endMs ?? 0) < ($1.endMs ?? 0) }
    }

    @ViewBuilder
    private var lastNightCard: some View {
        if let n = lastNight {
            SurfaceCard {
                VStack(alignment: .leading, spacing: MellowTheme.Spacing.md) {
                    SectionHeader(title: "Last night",
                                  subtitle: "Sleep stages from your ring") {
                        if let rr = n.medianRespiratoryRate {
                            Chip(text: String(format: "%.0f br/min", rr), tint: MellowTheme.spo2)
                        }
                    }
                    StageBar(stages: [
                        Stage(label: "Deep", minutes: n.deepMin, color: MellowTheme.spo2),
                        Stage(label: "Light/REM", minutes: n.lightRemMin, color: MellowTheme.sleep),
                        Stage(label: "Awake", minutes: n.wakeMin, color: MellowTheme.textTertiary)
                    ])
                    HStack(spacing: MellowTheme.Spacing.lg) {
                        nightStat("Asleep", StageBar.formatMinutes(n.asleepMin))
                        nightStat("Awakenings", "\(n.awakenings)")
                        if n.sleepAvgHrCount > 0 {
                            nightStat("Avg HR", "\(Int(n.avgHr.rounded())) bpm")
                        }
                    }
                }
            }
        }
    }

    private func nightStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.mellowLabel).foregroundColor(MellowTheme.textTertiary)
            Text(value).font(.mellowBody).foregroundColor(MellowTheme.textPrimary)
        }
    }

    // MARK: Trend charts

    // drop out-of-range temps (sync garbage/0s) so one bad sample cant blow out axis,
    // then resample to the recent window so the glance stays smooth
    private var tempChartCard: some View {
        let data = RingStore.minuteBinned(
            store.tempHistory.filter { $0.value > 20 && $0.value < 45 }, bucketMs: 300_000)
        return SurfaceCard {
            VStack(alignment: .leading, spacing: MellowTheme.Spacing.md) {
                SectionHeader(title: "Skin temperature", subtitle: "Recorded by your ring · drag to inspect") {
                    if let lo = data.map(\.value).min(), let hi = data.map(\.value).max() {
                        Chip(text: String(format: "%.1f–%.1f °C", lo, hi), tint: MellowTheme.temperature)
                    }
                }
                InteractiveTrendChart(samples: data, range: .day, color: MellowTheme.temperature,
                                      unit: "°C", valueFormat: { String(format: "%.1f", $0) })
                    .frame(height: 150)
            }
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        SurfaceCard {
            VStack(spacing: MellowTheme.Spacing.md) {
                Image(systemName: ringConnected ? "arrow.triangle.2.circlepath" : "moon.zzz.fill")
                    .font(.system(size: 38, weight: .light)).foregroundColor(MellowTheme.accent)
                Text(ringConnected ? "Syncing your ring…" : "Put your ring on")
                    .font(.mellowHeadline).foregroundColor(MellowTheme.textPrimary)
                    .multilineTextAlignment(.center)
                Text("Wear it for a bit and your heart rate, HRV, blood oxygen and skin temp show up here. Pull down to sync what it's already recorded.")
                    .font(.mellowCaption).foregroundColor(MellowTheme.textSecondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity).padding(.vertical, MellowTheme.Spacing.lg)
        }
    }

    // MARK: Formatters

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE, MMM d"; return f
    }()
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; return f
    }()
}

// MARK: - Preview

#Preview("Today") {
    NavigationStack { OverviewScreen() }
        .environmentObject(RingStore.previewPopulated)
        .environmentObject(RingSession(store: RingStore.previewPopulated))
        .environmentObject(MetricsStore())
}
