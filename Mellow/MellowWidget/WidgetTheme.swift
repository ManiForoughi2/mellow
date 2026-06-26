import SwiftUI

// MARK: - Color(hex:)

extension Color {
    // mirrors app helper; widget extension cant import app target
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: s).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch s.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
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

// subset of MellowTheme, keep in sync with Theme.swift in main app
enum WidgetTheme {
    static let bg = Color(hex: "#0A0B0D")
    static let bgRaised = Color(hex: "#101216")
    static let surface = Color(hex: "#15181E")
    static let fill = Color(hex: "#21262E")

    static let textPrimary = Color(hex: "#F4F6F8")
    static let textSecondary = Color(hex: "#A2ABB8")
    static let textTertiary = Color(hex: "#6B7480")

    static let accent = Color(hex: "#7C8CFF")
    static let heartRate = Color(hex: "#FF5C7A")

    static let scaleLow = Color(hex: "#FF4D5E")
    static let scaleMid = Color(hex: "#FFC23D")
    static let scaleHigh = Color(hex: "#3DDC97")

    static let background = LinearGradient(
        colors: [Color(hex: "#13161C"), Color(hex: "#0A0B0D")],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static func recoveryColor(for percent: Int) -> Color {
        switch percent {
        case ..<34: return scaleLow
        case 34...66: return scaleMid
        default: return scaleHigh
        }
    }

    // MARK: Typography (rounded, matches Font.mellow*)

    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .bold, design: .rounded) }
    static var headline: Font { .system(size: 17, weight: .semibold, design: .rounded) }
    static var body: Font { .system(size: 15, weight: .medium, design: .rounded) }
    static var caption: Font { .system(size: 13, weight: .medium, design: .rounded) }
    static var label: Font { .system(size: 11, weight: .semibold, design: .rounded) }
}

// MARK: - WidgetRingGauge

struct WidgetRingGauge<Center: View>: View {
    var progress: Double          // 0...1
    var lineWidth: CGFloat
    var tint: Color
    @ViewBuilder var center: () -> Center

    private var clamped: Double { max(0, min(1, progress)) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(WidgetTheme.fill, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(
                    AngularGradient(
                        colors: [tint.opacity(0.55), tint, tint.opacity(0.9)],
                        center: .center,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(270)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            center()
        }
        .padding(lineWidth / 2)
    }
}
