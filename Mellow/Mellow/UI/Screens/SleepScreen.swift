import SwiftUI
import Charts

// MARK: - SleepScreen (real, from the ring's stored night)

// time in bed from ring in_bed flag + HR/temp logged in that window
struct SleepScreen: View {
    @EnvironmentObject var store: RingStore
    @EnvironmentObject var session: RingSession

    private var window: ClosedRange<Date>? {
        guard let s = store.sleepStartDate, let e = store.sleepEndDate, e > s else { return nil }
        return s...e
    }
    private func inWindow(_ s: [RingStore.Sample]) -> [RingStore.Sample] {
        guard let w = window else { return [] }
        return s.filter { w.contains($0.date) }
    }
    private var sleepHR: [RingStore.Sample] { inWindow(store.hrHistorySmoothed) }
    private var sleepTemp: [RingStore.Sample] { inWindow(store.tempHistory) }

    private var duration: String? {
        guard let s = store.sleepStartDate, let e = store.sleepEndDate, e > s else { return nil }
        let mins = Int(e.timeIntervalSince(s) / 60)
        return "\(mins / 60)h \(mins % 60)m"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: MellowTheme.Spacing.lg) {
                if store.sawSleepFlags || window != nil {
                    summaryCard
                    if !sleepHR.isEmpty { sleepHRCard }
                    if !sleepTemp.isEmpty { sleepTempCard }
                    if sleepHR.isEmpty && sleepTemp.isEmpty { partialNote }
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
        .navigationTitle("Sleep")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await session.resync() }
    }

    private var summaryCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: MellowTheme.Spacing.md) {
                SectionHeader(title: "Last night",
                              subtitle: "Rebuilt from what your ring logged") {
                    Chip(text: store.inBed == true ? "IN BED" : "TRACKED",
                         icon: "bed.double.fill", tint: MellowTheme.sleep, filled: true)
                }
                HStack(spacing: MellowTheme.Spacing.md) {
                    sleepStat("Time in bed", duration ?? "—", "bed.double.fill", MellowTheme.sleep)
                    sleepStat("Low HR",
                              sleepHR.map(\.value).min().map { "\(Int($0))" } ?? "—",
                              "heart.fill", MellowTheme.heartRate)
                    sleepStat("Low temp",
                              sleepTemp.map(\.value).min().map { String(format: "%.1f", $0) } ?? "—",
                              "thermometer.medium", MellowTheme.temperature)
                }
                if let s = store.sleepStartDate, let e = store.sleepEndDate {
                    Text("Bed \(Self.t.string(from: s)) → \(Self.t.string(from: e)) · from the ring's in_bed log")
                        .font(.mellowLabel).foregroundColor(MellowTheme.textTertiary)
                }
            }
        }
    }

    private func sleepStat(_ title: String, _ value: String, _ icon: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .bold)).foregroundColor(tint)
                Text(title.uppercased()).font(.mellowLabel).foregroundColor(MellowTheme.textTertiary).lineLimit(1).minimumScaleFactor(0.8)
            }
            Text(value).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundColor(MellowTheme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(MellowTheme.Spacing.md)
        .background(RoundedRectangle(cornerRadius: MellowTheme.Radius.md, style: .continuous).fill(MellowTheme.fill.opacity(0.6)).overlay(RoundedRectangle(cornerRadius: MellowTheme.Radius.md, style: .continuous).strokeBorder(MellowTheme.stroke, lineWidth: 1)))
    }

    // a single night is a sub-day window: use 1D formatting (hour ticks) and break
    // the line only across real gaps within the night
    private var sleepHRCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: MellowTheme.Spacing.md) {
                SectionHeader(title: "Overnight heart rate",
                              subtitle: "\(sleepHR.count) readings · drag to inspect") {
                    if let lo = sleepHR.map(\.value).min(), let hi = sleepHR.map(\.value).max() {
                        Chip(text: "\(Int(lo))–\(Int(hi)) bpm", tint: MellowTheme.heartRate)
                    }
                }
                InteractiveTrendChart(samples: sleepHR, range: .day, color: MellowTheme.heartRate,
                                      unit: "bpm", valueFormat: { "\(Int($0.rounded()))" })
                    .frame(height: 160)
            }
        }
    }

    private var sleepTempCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: MellowTheme.Spacing.md) {
                SectionHeader(title: "Overnight temperature",
                              subtitle: "\(sleepTemp.count) readings · drag to inspect") {
                    if let lo = sleepTemp.map(\.value).min(), let hi = sleepTemp.map(\.value).max() {
                        Chip(text: String(format: "%.1f–%.1f °C", lo, hi), tint: MellowTheme.temperature)
                    }
                }
                InteractiveTrendChart(samples: sleepTemp, range: .day, color: MellowTheme.temperature,
                                      unit: "°C", valueFormat: { String(format: "%.1f", $0) })
                    .frame(height: 150)
            }
        }
    }

    private var partialNote: some View {
        SurfaceCard {
            VStack(spacing: 8) {
                Image(systemName: "moon.zzz.fill").font(.system(size: 30, weight: .light)).foregroundColor(MellowTheme.sleep)
                Text("Found a sleep window").font(.mellowHeadline).foregroundColor(MellowTheme.textPrimary)
                Text("The ring knows you were in bed, but hasn't handed over the heart-rate and temperature for that stretch yet. Give it a minute to finish the night, then pull down to sync.")
                    .font(.mellowCaption).foregroundColor(MellowTheme.textSecondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity).padding(.vertical, MellowTheme.Spacing.lg)
        }
    }

    private var empty: some View {
        SurfaceCard {
            VStack(spacing: MellowTheme.Spacing.md) {
                Image(systemName: "moon.stars.fill").font(.system(size: 38, weight: .light)).foregroundColor(MellowTheme.sleep)
                Text("No sleep yet").font(.mellowHeadline).foregroundColor(MellowTheme.textPrimary)
                Text("Wear the ring to bed. It records the night on its own. Open the app in the morning and pull down to grab it.")
                    .font(.mellowCaption).foregroundColor(MellowTheme.textSecondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity).padding(.vertical, MellowTheme.Spacing.lg)
        }
    }

    private static let t: DateFormatter = { let f = DateFormatter(); f.timeStyle = .short; return f }()
}

