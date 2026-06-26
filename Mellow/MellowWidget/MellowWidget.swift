import WidgetKit
import SwiftUI

// MARK: - Widget definition

struct MellowWidget: Widget {
    let kind = "MellowWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MellowProvider()) { entry in
            MellowWidgetView(entry: entry)
                .widgetContainerBackground(WidgetTheme.background)
        }
        .configurationDisplayName("Recovery")
        .description("Your latest recovery score and heart rate at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

// MARK: - Root view (family switch)

struct MellowWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MellowEntry

    var body: some View {
        switch family {
        case .systemMedium:
            MediumWidgetView(snapshot: entry.snapshot)
        default:
            SmallWidgetView(snapshot: entry.snapshot)
        }
    }
}

// MARK: - Small

struct SmallWidgetView: View {
    let snapshot: MellowSnapshot
    private var tint: Color { WidgetTheme.recoveryColor(for: snapshot.recovery) }

    var body: some View {
        VStack(spacing: 8) {
            WidgetRingGauge(progress: Double(snapshot.recovery) / 100.0,
                            lineWidth: 11,
                            tint: tint) {
                VStack(spacing: 0) {
                    Text("\(snapshot.recovery)")
                        .font(WidgetTheme.display(34))
                        .foregroundColor(WidgetTheme.textPrimary)
                    Text("RECOVERY")
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .foregroundColor(WidgetTheme.textTertiary)
                }
            }
            .frame(width: 96, height: 96)

            HStack(spacing: 5) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(WidgetTheme.heartRate)
                Text("\(snapshot.hr)")
                    .font(WidgetTheme.headline)
                    .foregroundColor(WidgetTheme.textPrimary)
                Text("bpm")
                    .font(WidgetTheme.label)
                    .foregroundColor(WidgetTheme.textTertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Medium

struct MediumWidgetView: View {
    let snapshot: MellowSnapshot
    private var tint: Color { WidgetTheme.recoveryColor(for: snapshot.recovery) }

    var body: some View {
        HStack(spacing: 18) {
            WidgetRingGauge(progress: Double(snapshot.recovery) / 100.0,
                            lineWidth: 12,
                            tint: tint) {
                VStack(spacing: 0) {
                    Text("\(snapshot.recovery)")
                        .font(WidgetTheme.display(40))
                        .foregroundColor(WidgetTheme.textPrimary)
                    Text("%")
                        .font(WidgetTheme.caption)
                        .foregroundColor(WidgetTheme.textTertiary)
                }
            }
            .frame(width: 116, height: 116)

            VStack(alignment: .leading, spacing: 10) {
                Text("Mellow")
                    .font(WidgetTheme.label)
                    .foregroundColor(WidgetTheme.accent)
                    .tracking(1.5)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Recovery")
                        .font(WidgetTheme.caption)
                        .foregroundColor(WidgetTheme.textSecondary)
                    Text(bandLabel)
                        .font(WidgetTheme.headline)
                        .foregroundColor(tint)
                }

                MetricRow(icon: "heart.fill",
                          tint: WidgetTheme.heartRate,
                          value: "\(snapshot.hr)",
                          unit: "bpm",
                          label: "Heart rate")

                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bandLabel: String {
        switch snapshot.recovery {
        case ..<34: return "Low"
        case 34...66: return "Moderate"
        default: return "High"
        }
    }
}

// MARK: - Pieces

private struct MetricRow: View {
    let icon: String
    let tint: Color
    let value: String
    let unit: String
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 18)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(WidgetTheme.headline)
                    .foregroundColor(WidgetTheme.textPrimary)
                Text(unit)
                    .font(WidgetTheme.label)
                    .foregroundColor(WidgetTheme.textTertiary)
            }
        }
    }
}

// MARK: - Background compatibility

extension View {
    // containerBackground required for iOS 17 widgets, unavailable on older SDKs
    @ViewBuilder
    func widgetContainerBackground<S: ShapeStyle>(_ style: S) -> some View {
        if #available(iOS 17.0, *) {
            containerBackground(style, for: .widget)
        } else {
            background(style)
        }
    }
}

// MARK: - Previews

#Preview("Small", as: .systemSmall) {
    MellowWidget()
} timeline: {
    MellowEntry(date: .now, snapshot: .demo)
    MellowEntry(date: .now, snapshot: MellowSnapshot(recovery: 42, hr: 78, date: .now, isPlaceholder: false))
    MellowEntry(date: .now, snapshot: MellowSnapshot(recovery: 21, hr: 96, date: .now, isPlaceholder: false))
}

#Preview("Medium", as: .systemMedium) {
    MellowWidget()
} timeline: {
    MellowEntry(date: .now, snapshot: .demo)
    MellowEntry(date: .now, snapshot: MellowSnapshot(recovery: 55, hr: 64, date: .now, isPlaceholder: false))
}
