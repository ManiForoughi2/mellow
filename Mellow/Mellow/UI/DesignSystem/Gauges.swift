import SwiftUI

// MARK: - RingGauge

struct RingGauge<Center: View>: View {
    // progress 0...1
    var progress: Double
    var lineWidth: CGFloat = 16
    var gradient: AngularGradient
    var trackColor: Color = MellowTheme.fill
    var startAngle: Angle = .degrees(-90)
    @ViewBuilder var center: () -> Center

    init(progress: Double,
         lineWidth: CGFloat = 16,
         gradient: AngularGradient,
         trackColor: Color = MellowTheme.fill,
         startAngle: Angle = .degrees(-90),
         @ViewBuilder center: @escaping () -> Center) {
        self.progress = progress
        self.lineWidth = lineWidth
        self.gradient = gradient
        self.trackColor = trackColor
        self.startAngle = startAngle
        self.center = center
    }

    init(progress: Double,
         lineWidth: CGFloat = 16,
         colors: [Color],
         trackColor: Color = MellowTheme.fill,
         @ViewBuilder center: @escaping () -> Center) {
        self.init(progress: progress,
                  lineWidth: lineWidth,
                  gradient: AngularGradient(colors: colors + [colors.first ?? .white],
                                            center: .center),
                  trackColor: trackColor,
                  center: center)
    }

    private var clamped: Double { max(0, min(1, progress)) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(trackColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(startAngle)
                .animation(.easeOut(duration: 0.8), value: clamped)
            center()
        }
        .padding(lineWidth / 2)
    }
}

// MARK: - ArcGauge

struct ArcGauge<Center: View>: View {
    // progress 0...1
    var progress: Double
    var lineWidth: CGFloat = 14
    var gradient: AngularGradient
    var trackColor: Color = MellowTheme.fill
    // total arc sweep in degrees
    var sweep: Double = 240
    @ViewBuilder var center: () -> Center

    init(progress: Double,
         lineWidth: CGFloat = 14,
         gradient: AngularGradient,
         trackColor: Color = MellowTheme.fill,
         sweep: Double = 240,
         @ViewBuilder center: @escaping () -> Center) {
        self.progress = progress
        self.lineWidth = lineWidth
        self.gradient = gradient
        self.trackColor = trackColor
        self.sweep = sweep
        self.center = center
    }

    init(progress: Double,
         lineWidth: CGFloat = 14,
         colors: [Color],
         trackColor: Color = MellowTheme.fill,
         sweep: Double = 240,
         @ViewBuilder center: @escaping () -> Center) {
        self.init(progress: progress,
                  lineWidth: lineWidth,
                  gradient: AngularGradient(
                    gradient: Gradient(colors: colors),
                    center: .center,
                    startAngle: .degrees(0),
                    endAngle: .degrees(sweep)),
                  trackColor: trackColor,
                  sweep: sweep,
                  center: center)
    }

    private var clamped: Double { max(0, min(1, progress)) }
    private var trimEnd: CGFloat { CGFloat(sweep / 360.0) }
    private var rotation: Angle { .degrees(90 + (360 - sweep) / 2) }

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: trimEnd)
                .stroke(trackColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(rotation)
            Circle()
                .trim(from: 0, to: trimEnd * CGFloat(clamped))
                .stroke(gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(rotation)
                .animation(.easeOut(duration: 0.8), value: clamped)
            center()
        }
        .padding(lineWidth / 2)
    }
}

// MARK: - MiniSparkline

struct MiniSparkline: View {
    let samples: [Double]
    var tint: Color = MellowTheme.accent
    var lineWidth: CGFloat = 2
    var showFill: Bool = true

    var body: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            ZStack {
                if showFill, pts.count > 1 {
                    fillPath(pts, height: geo.size.height)
                        .fill(LinearGradient(
                            colors: [tint.opacity(0.30), tint.opacity(0.0)],
                            startPoint: .top, endPoint: .bottom))
                }
                linePath(pts)
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth,
                                                     lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard samples.count > 1 else {
            return samples.isEmpty ? [] : [CGPoint(x: 0, y: size.height / 2)]
        }
        let minV = samples.min() ?? 0
        let maxV = samples.max() ?? 1
        let span = max(maxV - minV, 0.0001)
        let stepX = size.width / CGFloat(samples.count - 1)
        return samples.enumerated().map { i, v in
            let x = CGFloat(i) * stepX
            let y = size.height - CGFloat((v - minV) / span) * size.height
            return CGPoint(x: x, y: y)
        }
    }

    private func linePath(_ pts: [CGPoint]) -> Path {
        var p = Path()
        guard let first = pts.first else { return p }
        p.move(to: first)
        for pt in pts.dropFirst() { p.addLine(to: pt) }
        return p
    }

    private func fillPath(_ pts: [CGPoint], height: CGFloat) -> Path {
        var p = linePath(pts)
        if let last = pts.last { p.addLine(to: CGPoint(x: last.x, y: height)) }
        if let first = pts.first { p.addLine(to: CGPoint(x: first.x, y: height)) }
        p.closeSubpath()
        return p
    }
}

// MARK: - StageBar

struct Stage: Identifiable {
    let id = UUID()
    var label: String
    var minutes: Double
    var color: Color

    init(label: String, minutes: Double, color: Color) {
        self.label = label; self.minutes = minutes; self.color = color
    }
}

struct StageBar: View {
    let stages: [Stage]
    var height: CGFloat = 16
    var showLegend: Bool = true
    var cornerRadius: CGFloat = 8

    private var total: Double { max(stages.reduce(0) { $0 + $1.minutes }, 0.0001) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(stages) { s in
                        Rectangle()
                            .fill(s.color)
                            .frame(width: max(geo.size.width * CGFloat(s.minutes / total) - 2, 0))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .frame(height: height)

            if showLegend {
                HStack(spacing: 14) {
                    ForEach(stages) { s in
                        HStack(spacing: 5) {
                            Circle().fill(s.color).frame(width: 7, height: 7)
                            Text(s.label).font(.mellowLabel).foregroundColor(MellowTheme.textSecondary)
                            Text(StageBar.formatMinutes(s.minutes))
                                .font(.mellowLabel).foregroundColor(MellowTheme.textTertiary)
                        }
                    }
                }
            }
        }
    }

    static func formatMinutes(_ m: Double) -> String {
        let total = Int(m.rounded())
        let h = total / 60, mm = total % 60
        return h > 0 ? "\(h)h \(mm)m" : "\(mm)m"
    }
}

// MARK: - Previews

#Preview("Gauges") {
    ScrollView {
        VStack(spacing: 28) {
            RingGauge(progress: 0.74,
                      lineWidth: 18,
                      gradient: AngularGradient(
                        colors: [MellowTheme.scaleLow, MellowTheme.scaleMid, MellowTheme.scaleHigh],
                        center: .center)) {
                VStack(spacing: 0) {
                    Text("74").font(.mellowDisplay(56)).foregroundColor(MellowTheme.textPrimary)
                    Text("RECOVERY").font(.mellowLabel).foregroundColor(MellowTheme.textTertiary)
                }
            }
            .frame(width: 200, height: 200)

            ArcGauge(progress: 0.6,
                     lineWidth: 16,
                     colors: [MellowTheme.strain, MellowTheme.spo2]) {
                VStack(spacing: 0) {
                    Text("12.6").font(.mellowDisplay(48)).foregroundColor(MellowTheme.textPrimary)
                    Text("DAY STRAIN").font(.mellowLabel).foregroundColor(MellowTheme.textTertiary)
                }
            }
            .frame(width: 200, height: 200)

            SurfaceCard {
                MiniSparkline(samples: [52, 55, 60, 58, 72, 90, 84, 70, 64, 61, 80, 76],
                              tint: MellowTheme.heartRate)
                    .frame(height: 60)
            }

            SurfaceCard {
                StageBar(stages: [
                    Stage(label: "Awake", minutes: 24, color: MellowTheme.textTertiary),
                    Stage(label: "REM", minutes: 95, color: MellowTheme.sleep),
                    Stage(label: "Light", minutes: 220, color: MellowTheme.accent),
                    Stage(label: "Deep", minutes: 78, color: MellowTheme.spo2)
                ])
            }
        }
        .padding()
    }
    .mellowScreenBackground()
}
