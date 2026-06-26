import SwiftUI
import Charts

// MARK: - Time range (shared across metric screens)

// window selector. Day/week/month, with a sensible resample bucket
// and axis density per window so short windows stay fine-grained and long ones
// don't turn into noise.
enum TrendRange: String, CaseIterable, Identifiable {
    case day = "1D"
    case week = "1W"
    case month = "1M"
    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .day: return 24 * 3600
        case .week: return 7 * 24 * 3600
        case .month: return 30 * 24 * 3600
        }
    }
    var bucketMs: UInt64 {
        switch self {
        case .day: return 5 * 60_000        // 5 min
        case .week: return 60 * 60_000      // 1 h
        case .month: return 6 * 60 * 60_000 // 6 h
        }
    }
    // bucket in seconds (StressEngine and other resamplers want TimeInterval)
    var bucket: TimeInterval { Double(bucketMs) / 1000.0 }
    // split a line where a gap exceeds this (ring was off the finger)
    var gapSeconds: TimeInterval { bucket * 2.5 }

    var subtitle: String {
        switch self {
        case .day: return "Last 24 hours"
        case .week: return "Last 7 days"
        case .month: return "Last 30 days"
        }
    }
    var axisCount: Int {
        switch self {
        case .day: return 4
        case .week: return 4
        case .month: return 5
        }
    }
    var axisFormat: Date.FormatStyle {
        switch self {
        case .day: return .dateTime.hour()
        case .week: return .dateTime.weekday(.abbreviated)
        case .month: return .dateTime.month(.abbreviated).day()
        }
    }
    func calloutDate(_ d: Date) -> String {
        let f = DateFormatter()
        switch self {
        case .day: f.dateFormat = "h:mm a"
        case .week, .month: f.dateFormat = "EEE d · h:mm a"
        }
        return f.string(from: d)
    }
}

// MARK: - RangePicker (segmented pill)

struct TrendRangePicker: View {
    @Binding var range: TrendRange
    var onChange: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 4) {
            ForEach(TrendRange.allCases) { r in
                Button {
                    onChange?()
                    withAnimation(.easeInOut(duration: 0.2)) { range = r }
                } label: {
                    Text(r.rawValue)
                        .font(.mellowLabel).tracking(1)
                        .foregroundColor(range == r ? MellowTheme.textInverse : MellowTheme.textSecondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: MellowTheme.Radius.sm, style: .continuous)
                                .fill(range == r ? MellowTheme.accent : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: MellowTheme.Radius.md, style: .continuous)
                .fill(MellowTheme.fill)
                .overlay(RoundedRectangle(cornerRadius: MellowTheme.Radius.md, style: .continuous)
                    .strokeBorder(MellowTheme.stroke, lineWidth: 1))
        )
    }
}

// MARK: - InteractiveTrendChart

// One reusable metric chart:
//  • gradient area + rounded line, gap-aware (off-wrist stretches stay blank)
//  • touch-drag scrubbing with a vertical rule, a glowing cursor dot, and a
//    floating value/time callout pinned above the finger
//  • padded y-domain so a near-flat series doesn't collapse to a line
//  • clean leading y-axis + time x-axis with per-range formatting
//
// Pass the SAME data the caller already resampled (or let valueFormat handle it).
struct InteractiveTrendChart: View {
    let samples: [RingStore.Sample]
    let range: TrendRange
    let color: Color
    let unit: String
    var valueFormat: (Double) -> String = { String(format: "%.0f", $0) }
    // optional fixed y-domain (e.g. SpO2 90...100); nil = auto with headroom
    var yDomain: ClosedRange<Double>? = nil

    @State private var scrubDate: Date?

    private var scrub: RingStore.Sample? {
        guard let d = scrubDate else { return nil }
        return samples.min { abs($0.date.timeIntervalSince(d)) < abs($1.date.timeIntervalSince(d)) }
    }

    // MARK: Segments (break the line across off-wrist gaps)

    private struct Segment: Identifiable { let id: Int; let points: [RingStore.Sample] }

    private var segments: [Segment] {
        guard !samples.isEmpty else { return [] }
        let maxGap = range.gapSeconds
        var out: [Segment] = []
        var cur: [RingStore.Sample] = [samples[0]]
        for p in samples.dropFirst() {
            if p.date.timeIntervalSince(cur.last!.date) > maxGap {
                out.append(Segment(id: out.count, points: cur)); cur = [p]
            } else { cur.append(p) }
        }
        out.append(Segment(id: out.count, points: cur))
        return out
    }

    private var resolvedDomain: ClosedRange<Double> {
        if let d = yDomain { return d }
        let vals = samples.map(\.value)
        guard let lo = vals.min(), let hi = vals.max() else { return 0...1 }
        let pad = max((hi - lo) * 0.15, hi == lo ? max(abs(hi) * 0.05, 1) : 0.5)
        return (lo - pad)...(hi + pad)
    }

    var body: some View {
        Chart {
            ForEach(segments) { seg in
                ForEach(seg.points) { p in
                    AreaMark(x: .value("Time", p.date), y: .value(unit, p.value),
                             series: .value("seg", seg.id))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(LinearGradient(
                            colors: [color.opacity(0.28), color.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom))

                    LineMark(x: .value("Time", p.date), y: .value(unit, p.value),
                             series: .value("seg", seg.id))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(color)
                }
            }

            if let s = scrub {
                RuleMark(x: .value("Time", s.date))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(MellowTheme.textTertiary.opacity(0.55))
                PointMark(x: .value("Time", s.date), y: .value(unit, s.value))
                    .symbolSize(220).foregroundStyle(color.opacity(0.20))
                PointMark(x: .value("Time", s.date), y: .value(unit, s.value))
                    .symbolSize(70).foregroundStyle(color)
            } else if let last = samples.last {
                // resting end-dot so the latest reading always reads as "now"
                PointMark(x: .value("Time", last.date), y: .value(unit, last.value))
                    .symbolSize(60).foregroundStyle(color)
            }
        }
        .chartYScale(domain: resolvedDomain)
        .chartPlotStyle { $0.clipped() }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: range.axisCount)) { _ in
                AxisGridLine().foregroundStyle(MellowTheme.stroke.opacity(0.35))
                AxisValueLabel(format: range.axisFormat)
                    .foregroundStyle(MellowTheme.textTertiary).font(.mellowLabel)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(MellowTheme.stroke.opacity(0.35))
                AxisValueLabel().foregroundStyle(MellowTheme.textTertiary).font(.mellowLabel)
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
                                if let d: Date = proxy.value(atX: x) { scrubDate = d }
                            }
                            .onEnded { _ in scrubDate = nil }
                    )
                if let s = scrub, let plot = proxy.plotFrame,
                   let px = proxy.position(forX: s.date) {
                    callout(s)
                        .position(x: clampedX(px + geo[plot].origin.x, in: geo.size.width),
                                  y: geo[plot].origin.y + 4)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func callout(_ s: RingStore.Sample) -> some View {
        VStack(spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(valueFormat(s.value))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(MellowTheme.textPrimary)
                Text(unit).font(.mellowLabel).foregroundColor(MellowTheme.textTertiary)
            }
            Text(range.calloutDate(s.date))
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundColor(MellowTheme.textTertiary)
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(MellowTheme.surfaceElevated)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(color.opacity(0.5), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        )
        .fixedSize()
    }

    // keep the callout box on-screen at both edges
    private func clampedX(_ x: CGFloat, in width: CGFloat) -> CGFloat {
        min(max(x, 52), width - 52)
    }
}

// MARK: - TrendChartCard

// Card wrapper: header (title + min/max range chip), the interactive chart, and a
// built-in range picker so every metric screen gets the same affordance for free.
struct TrendChartCard: View {
    let title: String
    let subtitle: String
    let samples: [RingStore.Sample]
    let unit: String
    let color: Color
    var valueFormat: (Double) -> String = { String(format: "%.0f", $0) }
    var yDomain: ClosedRange<Double>? = nil
    var showRangePicker: Bool = true
    @Binding var range: TrendRange

    private var values: [Double] { samples.map(\.value) }
    private var avg: Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: MellowTheme.Spacing.md) {
                SectionHeader(title: title, subtitle: subtitle) {
                    if let lo = values.min(), let hi = values.max() {
                        Chip(text: "\(valueFormat(lo))–\(valueFormat(hi)) \(unit)", tint: color)
                    }
                }
                if showRangePicker {
                    TrendRangePicker(range: $range)
                }
                if samples.count >= 2 {
                    InteractiveTrendChart(samples: samples, range: range, color: color,
                                          unit: unit, valueFormat: valueFormat, yDomain: yDomain)
                        .frame(height: 200)
                    if let lo = values.min(), let hi = values.max(), let a = avg {
                        HStack(spacing: MellowTheme.Spacing.lg) {
                            footStat("LOW", valueFormat(lo), color)
                            footStat("AVG", valueFormat(a), MellowTheme.textSecondary)
                            footStat("HIGH", valueFormat(hi), color)
                            Spacer()
                        }
                    }
                } else {
                    emptyChart
                }
            }
        }
    }

    private func footStat(_ label: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.mellowLabel).foregroundColor(MellowTheme.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(tint)
                Text(unit).font(.mellowLabel).foregroundColor(MellowTheme.textTertiary)
            }
        }
    }

    private var emptyChart: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 26, weight: .light)).foregroundColor(color.opacity(0.6))
            Text("Not enough data in this window")
                .font(.mellowCaption).foregroundColor(MellowTheme.textTertiary)
            Text("Pull down to sync, or pick a wider range.")
                .font(.mellowLabel).foregroundColor(MellowTheme.textTertiary)
        }
        .frame(maxWidth: .infinity).frame(height: 160)
    }
}

// MARK: - Preview

#Preview("Interactive trend") {
    struct Demo: View {
        @State var range: TrendRange = .day
        var body: some View {
            let now = Date().timeIntervalSince1970 * 1000
            let samples: [RingStore.Sample] = (0..<120).map { i in
                let t = UInt64(now - Double(120 - i) * 5 * 60_000)
                let v = 60 + 12 * sin(Double(i) / 9) + Double((i * 7) % 9)
                return RingStore.Sample(timeMs: t, value: v)
            }
            return ScrollView {
                VStack(spacing: 16) {
                    TrendChartCard(title: "Heart rate", subtitle: range.subtitle,
                                   samples: samples, unit: "bpm",
                                   color: MellowTheme.heartRate, range: $range)
                }.padding()
            }
            .mellowScreenBackground()
        }
    }
    return Demo()
}
