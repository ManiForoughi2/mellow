import SwiftUI

// MARK: - Color(hex:)

extension Color {
    // accepts #RRGGBB, RRGGBB, #AARRGGBB or short #RGB; falls back to black on bad input
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: s).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch s.count {
        case 3: // RGB 12-bit
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RRGGBB 24-bit
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // AARRGGBB 32-bit
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(.sRGB,
                  red: Double(r) / 255.0,
                  green: Double(g) / 255.0,
                  blue: Double(b) / 255.0,
                  opacity: Double(a) / 255.0)
    }
}

// MARK: - MellowTheme

enum MellowTheme {

    // MARK: Backgrounds (light, white with a faint warm tint)

    static let bg = Color(hex: "#FFFDF7")          // near-white, hint of warm
    static let bgRaised = Color(hex: "#FFFFFF")    // cards sit slightly brighter than the page
    static let surface = Color(hex: "#FFFFFF")
    static let surfaceElevated = Color(hex: "#FFFFFF")
    static let stroke = Color(hex: "#EFE7D2")      // soft warm hairline
    static let fill = Color(hex: "#FBF3E0")        // gentle cream fill for chips/wells

    // MARK: Text (dark on light)

    static let textPrimary = Color(hex: "#1E1B14")    // near-black, warm
    static let textSecondary = Color(hex: "#6B6557")
    static let textTertiary = Color(hex: "#A39C8C")
    static let textInverse = Color(hex: "#FFFFFF")    // text on the amber accent

    // MARK: Brand accent (warm amber, used as accent NOT as page color)

    static let accent = Color(hex: "#F5B301")      // clean amber
    static let accentSoft = Color(hex: "#FFCE3A")

    // MARK: Per-metric solid colors

    // tuned to read cleanly on a light/white page (slightly deeper, less neon)
    static let recovery = Color(hex: "#1FB877")   // green
    static let strain = Color(hex: "#0E97BC")     // teal/blue
    static let sleep = Color(hex: "#6C5CE7")      // indigo
    static let heartRate = Color(hex: "#F2456B")  // red/pink
    static let hrv = Color(hex: "#1FB36A")        // green
    static let spo2 = Color(hex: "#0FA8C4")       // cyan
    static let temperature = Color(hex: "#EF7C2B")// orange
    static let strainCalm = Color(hex: "#2BB9A3")

    // MARK: Status / scale colors

    static let scaleLow = Color(hex: "#FF4D5E")     // red
    static let scaleMid = Color(hex: "#FFC23D")     // yellow
    static let scaleHigh = Color(hex: "#3DDC97")    // green
    static let warning = Color(hex: "#FFC23D")
    static let danger = Color(hex: "#FF4D5E")
    static let good = Color(hex: "#3DDC97")

    // MARK: Stress scale (calm → moderate → high)

    static let stressCalm = Color(hex: "#3DDC97")   // green, recovered
    static let stressMod  = Color(hex: "#FFC23D")   // yellow, moderate
    static let stressHigh = Color(hex: "#FF4D5E")   // red, high stress

    // stress band color for 0-100 value
    static func stressColor(_ v: Double) -> Color {
        switch v {
        case ..<34: return stressCalm
        case 34..<67: return stressMod
        default: return stressHigh
        }
    }

    // MARK: - Gradients

    // recovery: red -> yellow -> green, full-scale
    static let recoveryGradient = LinearGradient(
        colors: [Color(hex: "#FF4D5E"), Color(hex: "#FFC23D"), Color(hex: "#3DDC97")],
        startPoint: .leading, endPoint: .trailing)

    static let strainGradient = LinearGradient(
        colors: [Color(hex: "#1E7FB0"), Color(hex: "#2BB7D9"), Color(hex: "#5BE0E8")],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let sleepGradient = LinearGradient(
        colors: [Color(hex: "#5B4BD1"), Color(hex: "#8B7CFF"), Color(hex: "#B3A7FF")],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let heartRateGradient = LinearGradient(
        colors: [Color(hex: "#FF3D6E"), Color(hex: "#FF5C7A"), Color(hex: "#FF8FA3")],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let hrvGradient = LinearGradient(
        colors: [Color(hex: "#1FA85F"), Color(hex: "#46D17F"), Color(hex: "#7BE6A6")],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let spo2Gradient = LinearGradient(
        colors: [Color(hex: "#1B9FC0"), Color(hex: "#39D0E6"), Color(hex: "#86E9F5")],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let temperatureGradient = LinearGradient(
        colors: [Color(hex: "#FF7A2D"), Color(hex: "#FF9F45"), Color(hex: "#FFC178")],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let accentGradient = LinearGradient(
        colors: [Color(hex: "#FFCE3A"), Color(hex: "#F5B301")],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    // faint warm highlight at the top of a card, fading out
    static let surfaceSheen = LinearGradient(
        colors: [Color(hex: "#FFF7E0").opacity(0.5), Color.white.opacity(0.0)],
        startPoint: .top, endPoint: .bottom)

    // page: soft warm cream at top settling to white
    static let screenBackground = LinearGradient(
        colors: [Color(hex: "#FFF8E8"), Color(hex: "#FFFDF7")],
        startPoint: .top, endPoint: .bottom)

    // MARK: - Scale helpers

    // red <34, yellow 34-66, green >66
    static func recoveryColor(for percent: Int) -> Color {
        switch percent {
        case ..<34: return scaleLow
        case 34...66: return scaleMid
        default: return scaleHigh
        }
    }

    // continuous red->yellow->green interpolation for 0...100 score
    static func scoreColor(for percent: Int) -> Color {
        let t = max(0.0, min(1.0, Double(percent) / 100.0))
        let stops: [(Double, (Double, Double, Double))] = [
            (0.0, (1.0, 0.30, 0.37)),   // red
            (0.5, (1.0, 0.76, 0.24)),   // yellow
            (1.0, (0.24, 0.86, 0.59))   // green
        ]
        var lower = stops[0], upper = stops[stops.count - 1]
        for i in 0..<(stops.count - 1) where t >= stops[i].0 && t <= stops[i + 1].0 {
            lower = stops[i]; upper = stops[i + 1]
        }
        let span = upper.0 - lower.0
        let lt = span == 0 ? 0 : (t - lower.0) / span
        let r = lower.1.0 + (upper.1.0 - lower.1.0) * lt
        let g = lower.1.1 + (upper.1.1 - lower.1.1) * lt
        let b = lower.1.2 + (upper.1.2 - lower.1.2) * lt
        return Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    // strain 0...21 -> cool blue to bright teal
    static func strainColor(for strain: Double) -> Color {
        let t = max(0.0, min(1.0, strain / 21.0))
        return Color(.sRGB,
                     red: 0.12 + 0.24 * t,
                     green: 0.55 + 0.30 * t,
                     blue: 0.72 + 0.18 * t,
                     opacity: 1)
    }

    // MARK: - Spacing & radii

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let sm: CGFloat = 10
        static let md: CGFloat = 16
        static let lg: CGFloat = 22
        static let xl: CGFloat = 28
        static let pill: CGFloat = 999
    }

    enum Shadow {
        // soft warm-grey lift for cards on a light page (black would look dirty)
        static let color = Color(hex: "#C9A84A").opacity(0.18)
        static let radius: CGFloat = 16
        static let y: CGFloat = 8
    }
}

// MARK: - Typography

extension Font {
    static func mellowDisplay(_ size: CGFloat = 64) -> Font {
        .system(size: size, weight: .bold, design: .rounded)
    }
    static var mellowTitle: Font { .system(size: 22, weight: .bold, design: .rounded) }
    static var mellowHeadline: Font { .system(size: 17, weight: .semibold, design: .rounded) }
    static var mellowBody: Font { .system(size: 15, weight: .medium, design: .rounded) }
    static var mellowCaption: Font { .system(size: 13, weight: .medium, design: .rounded) }
    static var mellowLabel: Font { .system(size: 11, weight: .semibold, design: .rounded) }
}

extension Text {
    func mellowPrimary() -> Text { foregroundColor(MellowTheme.textPrimary) }
    func mellowSecondary() -> Text { foregroundColor(MellowTheme.textSecondary) }
}

// MARK: - View helpers

extension View {
    func mellowScreenBackground() -> some View {
        background(MellowTheme.screenBackground.ignoresSafeArea())
    }
}

#Preview("Theme palette") {
    ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            Text("Mellow Theme").font(.mellowTitle).foregroundColor(MellowTheme.textPrimary)

            HStack {
                ForEach(0...100, id: \.self) { p in
                    if p % 5 == 0 {
                        Rectangle().fill(MellowTheme.scoreColor(for: p)).frame(height: 28)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 8) {
                colorRow("recovery", MellowTheme.recovery)
                colorRow("strain", MellowTheme.strain)
                colorRow("sleep", MellowTheme.sleep)
                colorRow("heartRate", MellowTheme.heartRate)
                colorRow("hrv", MellowTheme.hrv)
                colorRow("spo2", MellowTheme.spo2)
                colorRow("temperature", MellowTheme.temperature)
            }

            Text("64").font(.mellowDisplay()).foregroundColor(MellowTheme.textPrimary)
            Text("Secondary text sample").font(.mellowBody).foregroundColor(MellowTheme.textSecondary)
        }
        .padding()
    }
    .mellowScreenBackground()
}

@ViewBuilder
private func colorRow(_ name: String, _ color: Color) -> some View {
    HStack {
        RoundedRectangle(cornerRadius: 6).fill(color).frame(width: 40, height: 24)
        Text(name).font(.mellowBody).foregroundColor(MellowTheme.textSecondary)
        Spacer()
    }
}
