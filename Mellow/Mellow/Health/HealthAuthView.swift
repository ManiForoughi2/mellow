import SwiftUI
import HealthKit

// MARK: - HealthAuthView

// write-only; never reads back from Health
struct HealthAuthView: View {

    @EnvironmentObject private var health: HealthKitBridge
    @Environment(\.dismiss) private var dismiss

    @State private var requesting = false

    private struct Item: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let detail: String
        let tint: Color
    }

    private let items: [Item] = [
        Item(icon: "heart.fill", title: "Heart rate",
             detail: "Beats per minute", tint: MellowTheme.heartRate),
        Item(icon: "waveform.path.ecg", title: "Heart rate variability",
             detail: "Stored as SDNN, in ms", tint: MellowTheme.hrv),
        Item(icon: "drop.fill", title: "Blood oxygen",
             detail: "SpO₂ percentage", tint: MellowTheme.spo2),
        Item(icon: "thermometer.medium", title: "Body temperature",
             detail: "Degrees Celsius", tint: MellowTheme.temperature)
    ]

    var body: some View {
        ZStack {
            MellowTheme.screenBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: MellowTheme.Spacing.xl) {
                    header
                    metricsCard
                    privacyNote
                    Spacer(minLength: MellowTheme.Spacing.lg)
                    actions
                }
                .padding(.horizontal, MellowTheme.Spacing.lg)
                .padding(.top, MellowTheme.Spacing.xl)
                .padding(.bottom, MellowTheme.Spacing.xxl)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: MellowTheme.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: MellowTheme.Radius.md, style: .continuous)
                    .fill(MellowTheme.heartRate.opacity(0.16))
                    .frame(width: 56, height: 56)
                Image(systemName: "heart.text.square.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(MellowTheme.heartRate)
            }
            Text("Export to Apple Health")
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .foregroundColor(MellowTheme.textPrimary)
            Text("Mellow can write your ring metrics to the Health app so they live alongside the rest of your data. This is one-way. Mellow never reads anything from Health.")
                .font(.mellowBody)
                .foregroundColor(MellowTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Metrics

    private var metricsCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: MellowTheme.Spacing.md) {
                Text("WHAT GETS EXPORTED")
                    .font(.mellowLabel)
                    .foregroundColor(MellowTheme.textTertiary)
                ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                    if idx > 0 {
                        Rectangle().fill(MellowTheme.stroke).frame(height: 1)
                    }
                    HStack(spacing: MellowTheme.Spacing.md) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(item.tint.opacity(0.16))
                                .frame(width: 34, height: 34)
                            Image(systemName: item.icon)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(item.tint)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.mellowBody)
                                .foregroundColor(MellowTheme.textPrimary)
                            Text(item.detail)
                                .font(.mellowCaption)
                                .foregroundColor(MellowTheme.textTertiary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: MellowTheme.Spacing.sm) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(MellowTheme.recovery)
            Text("You can change what Health stores any time in the Health app, and turn this off again in Mellow’s settings.")
                .font(.mellowCaption)
                .foregroundColor(MellowTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: MellowTheme.Spacing.md) {
            if health.isAuthorized {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(MellowTheme.good)
                    Text("Apple Health is connected")
                        .font(.mellowHeadline)
                        .foregroundColor(MellowTheme.textPrimary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, MellowTheme.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: MellowTheme.Radius.md, style: .continuous)
                        .fill(MellowTheme.good.opacity(0.12))
                )
            } else {
                Button(action: enable) {
                    HStack(spacing: 8) {
                        if requesting {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(MellowTheme.textInverse)
                        } else {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 15, weight: .bold))
                        }
                        Text(requesting ? "Connecting…" : "Enable Apple Health")
                            .font(.mellowHeadline)
                    }
                    .foregroundColor(MellowTheme.textInverse)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, MellowTheme.Spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: MellowTheme.Radius.md, style: .continuous)
                            .fill(MellowTheme.heartRateGradient)
                    )
                }
                .buttonStyle(.plain)
                .disabled(requesting || !health.isAvailable)
                .opacity(health.isAvailable ? 1 : 0.5)
            }

            if !health.isAvailable {
                Text("Apple Health isn’t available on this device.")
                    .font(.mellowCaption)
                    .foregroundColor(MellowTheme.textTertiary)
            } else if let err = health.lastError {
                Text(err)
                    .font(.mellowCaption)
                    .foregroundColor(MellowTheme.danger)
                    .multilineTextAlignment(.center)
            }

            Button("Not now") { dismiss() }
                .font(.mellowBody)
                .foregroundColor(MellowTheme.textSecondary)
                .padding(.top, 2)
        }
    }

    private func enable() {
        requesting = true
        health.exportEnabled = true
        Task {
            await health.requestAuthorization()
            requesting = false
            if health.isAuthorized { dismiss() }
        }
    }
}

// MARK: - Preview

#Preview("Health Auth") {
    HealthAuthView()
        .environmentObject(HealthKitBridge())
        .preferredColorScheme(.dark)
}
