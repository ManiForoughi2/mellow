import SwiftUI
import Charts

// MARK: - StressScreen (stress monitor)

// 0-100 stress from HRV + HR (see StressEngine); low HRV vs baseline + elevated HR = sympathetic
struct StressScreen: View {
    @EnvironmentObject var store: RingStore
    @EnvironmentObject var session: RingSession

    // stress uses the shared range type so the picker matches every other screen;
    // its resample buckets are tuned a touch coarser (stress is slow-moving)
    typealias Range = TrendRange

    @State private var range: TrendRange = .day
    @State private var scrub: StressEngine.Point?

    // MARK: Derived

    // baselines taken from whole history so "your normal" stays stable when window is short
    private var points: [StressEngine.Point] {
        let cutoff = Date().addingTimeInterval(-range.seconds)
        return StressEngine.series(hrv: store.hrvHistory, hr: store.hrHistory,
                                   bucket: range.bucket)
            .filter { $0.date >= cutoff }
    }

    private var hasData: Bool { points.count >= 2 }

    // "now" only counts when ring is worn and feeding fresh data, else hero shows "Not worn"
    private var isLiveNow: Bool { store.isWornNow }

    private var headline: StressEngine.Point? {
        if let s = scrub { return s }
        return isLiveNow ? points.last : nil
    }

    private var avg: Double? {
        guard !points.isEmpty else { return nil }
        return points.map(\.stress).reduce(0, +) / Double(points.count)
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(spacing: MellowTheme.Spacing.lg) {
                hero
                rangePicker
                if hasData { chartCard } else { emptyState }
                if hasData { summaryRow }
                liveCard
            }
            .padding(.horizontal, MellowTheme.Spacing.lg)
            .padding(.top, MellowTheme.Spacing.md)
            .padding(.bottom, MellowTheme.Spacing.xxl)
        }
        .scrollIndicators(.hidden)
        .mellowScreenBackground()
        .navigationTitle("Stress")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await session.resync() }
        .onDisappear { if session.liveHRActive { session.stopLiveHR() } }
    }

    // MARK: Hero

    private var hero: some View {
        let value = headline?.stress
        let band = value.map(StressEngine.Band.of)
        let color = value.map(MellowTheme.stressColor) ?? MellowTheme.textTertiary
        // "Not worn" only when not scrubbing history and ring is off
        let notWorn = scrub == nil && !isLiveNow
        return VStack(spacing: 6) {
            Text(scrub == nil ? "STRESS NOW" : "STRESS")
                .font(.mellowLabel).tracking(2).foregroundColor(MellowTheme.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value.map { "\(Int($0.rounded()))" } ?? "—")
                    .font(.system(size: 72, weight: .heavy, design: .rounded))
                    .foregroundColor(color)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: value ?? 0))
            }
            if notWorn {
                Text("RING NOT WORN")
                    .font(.mellowLabel).tracking(2)
                    .foregroundColor(MellowTheme.textTertiary)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(MellowTheme.fill))
                Text("Put the ring on to read your stress now.")
                    .font(.mellowLabel).foregroundColor(MellowTheme.textTertiary)
            } else if let band {
                Text(band.rawValue.uppercased())
                    .font(.mellowLabel).tracking(2)
                    .foregroundColor(color)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(color.opacity(0.16)))
            }
            if let s = scrub {
                Text(Self.scrubFormatter.string(from: s.date))
                    .font(.mellowLabel).foregroundColor(MellowTheme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, MellowTheme.Spacing.sm)
        .animation(.easeOut(duration: 0.15), value: value)
    }

    // MARK: Range picker

    private var rangePicker: some View {
        TrendRangePicker(range: $range) { scrub = nil }
    }

    // MARK: Chart

    private var chartCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: MellowTheme.Spacing.md) {
                SectionHeader(title: "Stress trend",
                              subtitle: range.subtitle) {
                    if let a = avg {
                        Chip(text: "avg \(Int(a.rounded()))", tint: MellowTheme.stressColor(a))
                    }
                }
                StressChart(points: points, range: range, scrub: $scrub)
                    .frame(height: 220)
                legend
            }
        }
    }

    private var legend: some View {
        HStack(spacing: MellowTheme.Spacing.md) {
            legendDot("Calm", MellowTheme.stressCalm)
            legendDot("Moderate", MellowTheme.stressMod)
            legendDot("High", MellowTheme.stressHigh)
            Spacer()
        }
    }

    private func legendDot(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.mellowLabel).foregroundColor(MellowTheme.textTertiary)
        }
    }

    // MARK: Summary row (time-in-band)

    private var summaryRow: some View {
        let total = max(points.count, 1)
        let calm = points.filter { $0.stress < 34 }.count
        let mod = points.filter { $0.stress >= 34 && $0.stress < 67 }.count
        let high = points.filter { $0.stress >= 67 }.count
        return VStack(alignment: .leading, spacing: MellowTheme.Spacing.md) {
            SectionHeader(title: "Time in band", subtitle: "Across the window")
            HStack(spacing: MellowTheme.Spacing.md) {
                bandStat("Calm", calm, total, MellowTheme.stressCalm)
                bandStat("Moderate", mod, total, MellowTheme.stressMod)
                bandStat("High", high, total, MellowTheme.stressHigh)
            }
        }
    }

    private func bandStat(_ label: String, _ count: Int, _ total: Int, _ color: Color) -> some View {
        let pct = Int((Double(count) / Double(total) * 100).rounded())
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(label.uppercased()).font(.mellowLabel).foregroundColor(MellowTheme.textTertiary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            Text("\(pct)%").font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(MellowTheme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(MellowTheme.Spacing.md)
        .background(RoundedRectangle(cornerRadius: MellowTheme.Radius.md, style: .continuous)
            .fill(MellowTheme.fill.opacity(0.6))
            .overlay(RoundedRectangle(cornerRadius: MellowTheme.Radius.md, style: .continuous)
                .strokeBorder(MellowTheme.stroke, lineWidth: 1)))
    }

    // MARK: Live measure

    private var liveCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: MellowTheme.Spacing.md) {
                SectionHeader(title: "Live",
                              subtitle: store.instantHrBpm != nil ? "Reading now" : "Tap to measure") {
                    if let hr = store.instantHrBpm {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Image(systemName: "heart.fill").font(.system(size: 12)).foregroundColor(MellowTheme.heartRate)
                            Text("\(Int(hr.rounded()))").font(.mellowHeadline).foregroundColor(MellowTheme.textPrimary)
                            Text("bpm").font(.mellowLabel).foregroundColor(MellowTheme.textTertiary)
                        }
                    }
                }
                Button {
                    if session.liveHRActive { session.stopLiveHR() } else { session.startLiveHR() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: session.liveHRActive ? "stop.fill" : "heart.text.square.fill")
                            .font(.system(size: 17, weight: .bold))
                        Text(session.liveHRActive ? "Stop measuring" : "Measure now")
                            .font(.mellowHeadline)
                    }
                    .foregroundColor(MellowTheme.textInverse)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: MellowTheme.Radius.pill, style: .continuous)
                            .fill(session.liveHRActive
                                  ? AnyShapeStyle(MellowTheme.textTertiary)
                                  : AnyShapeStyle(MellowTheme.accentGradient))
                    )
                }
                .buttonStyle(.plain)
                Text("A live reading sharpens your current stress. It runs the optical sensor, so it drains the ring — tap stop when you're done.")
                    .font(.mellowLabel).foregroundColor(MellowTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Empty

    private var emptyState: some View {
        SurfaceCard {
            VStack(spacing: MellowTheme.Spacing.md) {
                Image(systemName: "waveform.path.ecg.rectangle")
                    .font(.system(size: 36, weight: .light)).foregroundColor(MellowTheme.accent)
                Text("Not enough yet").font(.mellowHeadline).foregroundColor(MellowTheme.textPrimary)
                Text("Stress is read from your heart-rate variability. Wear the ring for a while, pull down to sync, and the trend fills in.")
                    .font(.mellowCaption).foregroundColor(MellowTheme.textSecondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity).padding(.vertical, MellowTheme.Spacing.lg)
        }
    }

    private static let scrubFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d, h:mm a"; return f
    }()
}

// MARK: - StressChart

private struct StressChart: View {
    let points: [StressEngine.Point]
    let range: StressScreen.Range
    @Binding var scrub: StressEngine.Point?

    // one continuous wear period; line drawn per-segment so off-wrist gaps stay blank
    private struct Segment: Identifiable { let id: Int; let points: [StressEngine.Point] }

    // split where consecutive gap exceeds ~2.5x bucket (ring stopped reporting)
    private var segments: [Segment] {
        guard !points.isEmpty else { return [] }
        let maxGap = range.bucket * 2.5
        var out: [Segment] = []
        var cur: [StressEngine.Point] = [points[0]]
        for p in points.dropFirst() {
            if p.date.timeIntervalSince(cur.last!.date) > maxGap {
                out.append(Segment(id: out.count, points: cur))
                cur = [p]
            } else {
                cur.append(p)
            }
        }
        out.append(Segment(id: out.count, points: cur))
        return out
    }

    var body: some View {
        Chart {
            RectangleMark(yStart: .value("lo", 0), yEnd: .value("hi", 34))
                .foregroundStyle(MellowTheme.stressCalm.opacity(0.06))
            RectangleMark(yStart: .value("lo", 34), yEnd: .value("hi", 67))
                .foregroundStyle(MellowTheme.stressMod.opacity(0.06))
            RectangleMark(yStart: .value("lo", 67), yEnd: .value("hi", 100))
                .foregroundStyle(MellowTheme.stressHigh.opacity(0.07))

            // each wear-segment its own series so line/fill break across off-wrist
            // gaps instead of interpolating a fake level for a period ring was off
            ForEach(segments) { seg in
                ForEach(seg.points) { p in
                    AreaMark(x: .value("Time", p.date), y: .value("Stress", p.stress),
                             series: .value("seg", seg.id))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(LinearGradient(
                            colors: [MellowTheme.accent.opacity(0.32), MellowTheme.accent.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom))

                    LineMark(x: .value("Time", p.date), y: .value("Stress", p.stress),
                             series: .value("seg", seg.id))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .foregroundStyle(LinearGradient(
                            colors: [MellowTheme.stressCalm, MellowTheme.stressMod, MellowTheme.stressHigh],
                            startPoint: .bottom, endPoint: .top))
                }
            }

            if let s = scrub {
                RuleMark(x: .value("Time", s.date))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(MellowTheme.textTertiary.opacity(0.6))
                PointMark(x: .value("Time", s.date), y: .value("Stress", s.stress))
                    .symbolSize(120)
                    .foregroundStyle(MellowTheme.stressColor(s.stress))
            } else if let last = points.last {
                PointMark(x: .value("Time", last.date), y: .value("Stress", last.stress))
                    .symbolSize(90)
                    .foregroundStyle(MellowTheme.stressColor(last.stress))
            }
        }
        .chartYScale(domain: 0...100)
        .chartPlotStyle { $0.clipped() }   // keep smoothed line inside 0-100
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { _ in
                AxisGridLine().foregroundStyle(MellowTheme.stroke.opacity(0.4))
                AxisValueLabel().foregroundStyle(MellowTheme.textTertiary).font(.mellowLabel)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: range.axisCount)) { value in
                AxisGridLine().foregroundStyle(MellowTheme.stroke.opacity(0.3))
                AxisValueLabel(format: range.axisFormat)
                    .foregroundStyle(MellowTheme.textTertiary).font(.mellowLabel)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(Color.clear).contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { g in
                                guard let plot = proxy.plotFrame else { return }
                                let x = g.location.x - geo[plot].origin.x
                                if let date: Date = proxy.value(atX: x) {
                                    scrub = nearest(to: date)
                                }
                            }
                            .onEnded { _ in scrub = nil }
                    )
            }
        }
    }

    private func nearest(to date: Date) -> StressEngine.Point? {
        points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }
}

// MARK: - Preview

#Preview("Stress") {
    NavigationStack { StressScreen() }
        .environmentObject(RingStore.previewPopulated)
        .environmentObject(RingSession(store: RingStore.previewPopulated))
}
