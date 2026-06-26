import SwiftUI

// MARK: - SurfaceCard / GlassCard

struct SurfaceCard<Content: View>: View {
    var cornerRadius: CGFloat = MellowTheme.Radius.lg
    var padding: CGFloat = MellowTheme.Spacing.lg
    var fill: Color = MellowTheme.surface
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(MellowTheme.surfaceSheen)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(MellowTheme.stroke, lineWidth: 1)
                    )
            )
            .shadow(color: MellowTheme.Shadow.color,
                    radius: MellowTheme.Shadow.radius, x: 0, y: MellowTheme.Shadow.y)
    }
}

struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = MellowTheme.Radius.lg
    var padding: CGFloat = MellowTheme.Spacing.lg
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .light)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(MellowTheme.stroke, lineWidth: 1)
                    )
            )
            .shadow(color: MellowTheme.Shadow.color, radius: 14, x: 0, y: 8)
    }
}

// MARK: - SectionHeader

struct SectionHeader<Accessory: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: () -> Accessory

    init(title: String, subtitle: String? = nil,
         @ViewBuilder accessory: @escaping () -> Accessory) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.mellowHeadline)
                    .foregroundColor(MellowTheme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.mellowCaption)
                        .foregroundColor(MellowTheme.textTertiary)
                }
            }
            Spacer(minLength: 8)
            accessory()
        }
    }
}

extension SectionHeader where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle, accessory: { EmptyView() })
    }
}

// MARK: - StatTile

struct StatTile: View {
    let title: String
    let value: String
    var unit: String?
    var icon: String?
    var tint: Color = MellowTheme.accent

    var body: some View {
        SurfaceCard(cornerRadius: MellowTheme.Radius.md, padding: MellowTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(tint)
                    }
                    Text(title.uppercased())
                        .font(.mellowLabel)
                        .foregroundColor(MellowTheme.textTertiary)
                    Spacer(minLength: 0)
                }
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(MellowTheme.textPrimary)
                    if let unit {
                        Text(unit)
                            .font(.mellowCaption)
                            .foregroundColor(MellowTheme.textSecondary)
                    }
                }
            }
        }
    }
}

// MARK: - Chip / Pill

struct Chip: View {
    let text: String
    var icon: String?
    var tint: Color = MellowTheme.accent
    var filled: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon).font(.system(size: 10, weight: .bold))
            }
            Text(text).font(.mellowLabel)
        }
        .foregroundColor(filled ? MellowTheme.textInverse : tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(filled ? tint : tint.opacity(0.15))
        )
    }
}

// MARK: - TrendBadge

// goodWhenUp: whether up arrow is green (good) or red (bad)
struct TrendBadge: View {
    let delta: Double
    var unit: String = ""
    var goodWhenUp: Bool = true
    var decimals: Int = 0

    private var isUp: Bool { delta >= 0 }
    private var color: Color {
        if abs(delta) < 0.0001 { return MellowTheme.textTertiary }
        let good = isUp ? goodWhenUp : !goodWhenUp
        return good ? MellowTheme.good : MellowTheme.danger
    }
    private var formatted: String {
        let v = abs(delta)
        return decimals > 0 ? String(format: "%.\(decimals)f", v) : "\(Int(v.rounded()))"
    }

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: abs(delta) < 0.0001 ? "minus" : (isUp ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill"))
                .font(.system(size: 8, weight: .black))
            Text(formatted + unit).font(.mellowLabel)
        }
        .foregroundColor(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.15)))
    }
}

// MARK: - ZoneBar

struct ZoneSegment: Identifiable {
    let id = UUID()
    var value: Double
    var color: Color
    var label: String?

    init(value: Double, color: Color, label: String? = nil) {
        self.value = value; self.color = color; self.label = label
    }
}

struct ZoneBar: View {
    let segments: [ZoneSegment]
    var height: CGFloat = 12
    var spacing: CGFloat = 2

    private var total: Double { max(segments.reduce(0) { $0 + $1.value }, 0.0001) }

    var body: some View {
        GeometryReader { geo in
            let usable = geo.size.width - spacing * CGFloat(max(segments.count - 1, 0))
            HStack(spacing: spacing) {
                ForEach(segments) { seg in
                    RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                        .fill(seg.color)
                        .frame(width: max(usable * CGFloat(seg.value / total), 0))
                }
            }
        }
        .frame(height: height)
    }
}

// MARK: - Previews

#Preview("Cards & headers") {
    ScrollView {
        VStack(spacing: 16) {
            SectionHeader(title: "Today", subtitle: "Tuesday, June 8") {
                Chip(text: "LIVE", icon: "dot.radiowaves.left.and.right", tint: MellowTheme.recovery, filled: true)
            }
            SurfaceCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Surface card").font(.mellowHeadline).foregroundColor(MellowTheme.textPrimary)
                    Text("Layered dark surface with sheen + stroke.")
                        .font(.mellowCaption).foregroundColor(MellowTheme.textSecondary)
                }
            }
            GlassCard {
                Text("Glass card").font(.mellowHeadline).foregroundColor(MellowTheme.textPrimary)
            }
            HStack(spacing: 12) {
                StatTile(title: "Resting HR", value: "52", unit: "bpm", icon: "heart.fill", tint: MellowTheme.heartRate)
                StatTile(title: "HRV", value: "78", unit: "ms", icon: "waveform.path.ecg", tint: MellowTheme.hrv)
            }
            HStack {
                Chip(text: "Optimal", tint: MellowTheme.good)
                Chip(text: "Elevated", icon: "flame.fill", tint: MellowTheme.temperature)
                Chip(text: "Filled", tint: MellowTheme.accent, filled: true)
                TrendBadge(delta: 6, unit: "%", goodWhenUp: true)
                TrendBadge(delta: -3, unit: "ms", goodWhenUp: true)
            }
            ZoneBar(segments: [
                ZoneSegment(value: 90, color: MellowTheme.sleep),
                ZoneSegment(value: 110, color: MellowTheme.accent),
                ZoneSegment(value: 200, color: MellowTheme.spo2),
                ZoneSegment(value: 30, color: MellowTheme.textTertiary)
            ])
        }
        .padding()
    }
    .mellowScreenBackground()
}
