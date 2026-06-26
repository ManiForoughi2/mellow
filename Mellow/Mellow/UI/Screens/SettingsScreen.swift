import SwiftUI

// MARK: - SettingsScreen

struct SettingsScreen: View {

    @EnvironmentObject private var store: RingStore
    @EnvironmentObject private var health: HealthKitBridge
    @EnvironmentObject private var session: RingSession
    @EnvironmentObject private var connect: ConnectController

    @AppStorage("mellow.useMetric") private var useMetric = true
    // birth date as unix timestamp, 0 = not set; drives age for HR-max/strain zones/VO₂max
    // AppModel reads same key
    @AppStorage("mellow.birthDate") private var birthDateTS: Double = 0

    @State private var showKey = false
    @State private var shareKeyItem: String?
    @State private var copied = false

    private var keyHex: String? { AuthKeyStore.load()?.map { String(format: "%02x", $0) }.joined() }
    // first 4 + last 4 hex chars, middle hidden
    private var maskedKey: String {
        guard let k = keyHex, k.count >= 8 else { return "Not provisioned" }
        return "\(k.prefix(4))••••••••\(k.suffix(4))"
    }

    @State private var showReleaseConfirm = false
    @State private var showReleaseGuidance = false

    var body: some View {
        ZStack {
            MellowTheme.screenBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: MellowTheme.Spacing.xl) {
                    header
                    profileSection
                    deviceSection
                    dataSection
                    keySection
                    aboutSection
                    footer
                }
                .padding(.horizontal, MellowTheme.Spacing.lg)
                .padding(.top, MellowTheme.Spacing.lg)
                .padding(.bottom, MellowTheme.Spacing.xxl)
            }
        }
        .alert("Release this ring?", isPresented: $showReleaseConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Release", role: .destructive) { session.factoryReset() }
        } message: {
            Text("This wipes Mellow's key and returns the ring to Oura. You'll set it up again in the Oura app.")
        }
        .alert("Ring released", isPresented: $showReleaseGuidance) {
            Button("Done", role: .cancel) { }
        } message: {
            Text("Now open Settings → Bluetooth → tap ⓘ by the Oura ring → Forget This Device, then set it up in the Oura app.")
        }
        .onChange(of: session.releaseState) { _, newValue in
            if newValue == .released {
                showReleaseGuidance = true
                connect.syncAuthKeyState()   // key wiped, flip app back to onboarding
            }
        }
        .sheet(isPresented: Binding(get: { shareKeyItem != nil },
                                    set: { if !$0 { shareKeyItem = nil } })) {
            if let item = shareKeyItem {
                ShareSheet(items: ["Mellow ring auth key:\n\(item)"])
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Settings")
                .font(.system(size: 32, weight: .heavy, design: .rounded))
                .foregroundColor(MellowTheme.textPrimary)
            Text("Manage your ring, data, and key.")
                .font(.mellowBody)
                .foregroundColor(MellowTheme.textSecondary)
        }
    }

    // MARK: Profile

    // picker defaults to ~30 years ago when unset, but stored value stays 0
    // until user picks, so age personalization is opt-in
    private var birthDateBinding: Binding<Date> {
        Binding(
            get: {
                birthDateTS > 0
                    ? Date(timeIntervalSince1970: birthDateTS)
                    : Calendar.current.date(byAdding: .year, value: -30, to: Date()) ?? Date()
            },
            set: { birthDateTS = $0.timeIntervalSince1970 }
        )
    }

    private var ageYears: Int? {
        guard birthDateTS > 0 else { return nil }
        let birth = Date(timeIntervalSince1970: birthDateTS)
        return Calendar.current.dateComponents([.year], from: birth, to: Date()).year
    }

    private var profileSection: some View {
        SettingsSection(title: "Profile", icon: "person.fill", tint: MellowTheme.heartRate) {
            HStack(spacing: MellowTheme.Spacing.md) {
                SettingsRowIcon(icon: "birthday.cake.fill", tint: MellowTheme.heartRate)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Birth date")
                        .font(.mellowHeadline)
                        .foregroundColor(MellowTheme.textPrimary)
                    Text(ageYears.map { "Age \($0). Sets your heart-rate zones." }
                         ?? "Set it to tune your heart-rate zones")
                        .font(.mellowCaption)
                        .foregroundColor(MellowTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                DatePicker("", selection: birthDateBinding,
                           in: ...Date(), displayedComponents: .date)
                    .labelsHidden()
                    .tint(MellowTheme.accent)
            }
        }
    }

    // MARK: Device

    private var deviceSection: some View {
        SettingsSection(title: "Device", icon: "circle.circle", tint: MellowTheme.accent) {
            SettingsInfoRow(icon: "tag.fill", title: "Ring name",
                            value: "Mellow Ring", tint: MellowTheme.accent)
            SettingsDivider()
            SettingsInfoRow(icon: "battery.75", title: "Battery",
                            value: store.batteryPercent.map { "\($0)%" } ?? "—",
                            tint: batteryTint)
            SettingsDivider()
            SettingsInfoRow(icon: "dot.radiowaves.left.and.right",
                            title: "Connection",
                            value: store.statusLine,
                            tint: store.isSyncing ? MellowTheme.good : MellowTheme.textTertiary)
            SettingsDivider()
            HStack(spacing: MellowTheme.Spacing.md) {
                SettingsButton(title: "Re-provision", icon: "arrow.triangle.2.circlepath",
                               tint: MellowTheme.accent) {
                    connect.resetAndReclaim()
                }
                SettingsButton(title: isReleasing ? "Releasing…" : "Forget ring",
                               icon: "trash",
                               tint: MellowTheme.danger, destructive: true) {
                    showReleaseConfirm = true
                }
                .disabled(isReleasing)
            }
            .padding(.top, 4)

            if isReleasing {
                HStack(spacing: 8) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(MellowTheme.danger)
                    Text("Returning ring to Oura…")
                        .font(.mellowCaption)
                        .foregroundColor(MellowTheme.textTertiary)
                }
                .padding(.top, 2)
            }
        }
    }

    private var isReleasing: Bool { session.releaseState == .releasing }

    private var batteryTint: Color {
        switch store.batteryPercent ?? 0 {
        case ..<20: return MellowTheme.danger
        case 20..<50: return MellowTheme.warning
        default: return MellowTheme.good
        }
    }

    // MARK: Data

    private var dataSection: some View {
        SettingsSection(title: "Data", icon: "externaldrive.fill", tint: MellowTheme.spo2) {
            HealthExportRow(health: health)
            SettingsDivider()
            SettingsSegmentRow(icon: "ruler", title: "Units",
                               tint: MellowTheme.strain,
                               options: ["Metric", "Imperial"],
                               selectedIndex: Binding(
                                get: { useMetric ? 0 : 1 },
                                set: { useMetric = ($0 == 0) }))
        }
    }

    // MARK: Key

    private var keySection: some View {
        SettingsSection(title: "Auth key", icon: "key.fill", tint: MellowTheme.recovery) {
            HStack(spacing: MellowTheme.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(MellowTheme.recovery.opacity(0.16))
                        .frame(width: 38, height: 38)
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(MellowTheme.recovery)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Key provisioned")
                        .font(.mellowHeadline)
                        .foregroundColor(MellowTheme.textPrimary)
                    Text(showKey ? maskedKey.replacingOccurrences(of: "•", with: "0")
                                 : maskedKey)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(MellowTheme.textSecondary)
                }
                Spacer(minLength: 0)
                Button {
                    withAnimation(.easeInOut) { showKey.toggle() }
                } label: {
                    Image(systemName: showKey ? "eye.slash" : "eye")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(MellowTheme.textTertiary)
                }
                .buttonStyle(.plain)
            }
            SettingsDivider()
            HStack(spacing: MellowTheme.Spacing.md) {
                SettingsButton(title: copied ? "Copied!" : "Copy key", icon: "doc.on.doc",
                               tint: MellowTheme.accent) {
                    if let k = keyHex {
                        UIPasteboard.general.string = k
                        withAnimation { copied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    }
                }
                SettingsButton(title: "Export key", icon: "square.and.arrow.up",
                               tint: MellowTheme.accent) {
                    shareKeyItem = keyHex
                }
            }
            .padding(.top, 4)
            .disabled(keyHex == nil)

            Text("This key is what lets Mellow talk to your ring. It never leaves your device.")
                .font(.mellowCaption)
                .foregroundColor(MellowTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }

    // MARK: About

    private var aboutSection: some View {
        SettingsSection(title: "About", icon: "info.circle.fill", tint: MellowTheme.textSecondary) {
            SettingsInfoRow(icon: "number", title: "Version",
                            value: appVersion, tint: MellowTheme.textSecondary)
            SettingsDivider()

            Text("Mellow talks straight to your Oura Ring over Bluetooth. No Oura account, no cloud, no subscription. You set up your own key, and your data stays on your phone.")
                .font(.mellowCaption)
                .foregroundColor(MellowTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 4)

            SettingsDivider()
            HStack(alignment: .top, spacing: MellowTheme.Spacing.md) {
                Image(systemName: "lock.shield").font(.system(size: 15, weight: .semibold))
                    .foregroundColor(MellowTheme.good).frame(width: 24)
                Text("Everything stays on this device. No servers, no network requests. Your biometric data never leaves your phone.")
                    .font(.mellowCaption).foregroundColor(MellowTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
    }

    private var footer: some View {
        Text("Mellow is an independent project and is not affiliated with or endorsed by Ōura Health Oy. For personal, educational use.")
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundColor(MellowTheme.textTertiary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.top, MellowTheme.Spacing.sm)
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}

// MARK: - Section container

private struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    var tint: Color = MellowTheme.accent
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: MellowTheme.Spacing.md) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(tint)
                Text(title.uppercased())
                    .font(.mellowLabel)
                    .foregroundColor(MellowTheme.textTertiary)
            }
            .padding(.leading, 4)

            SurfaceCard {
                VStack(alignment: .leading, spacing: MellowTheme.Spacing.md) {
                    content()
                }
            }
        }
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(MellowTheme.stroke)
            .frame(height: 1)
    }
}

// MARK: - Rows

private struct SettingsInfoRow: View {
    let icon: String
    let title: String
    let value: String
    var tint: Color = MellowTheme.accent

    var body: some View {
        HStack(spacing: MellowTheme.Spacing.md) {
            SettingsRowIcon(icon: icon, tint: tint)
            Text(title)
                .font(.mellowBody)
                .foregroundColor(MellowTheme.textPrimary)
            Spacer(minLength: 8)
            Text(value)
                .font(.mellowBody)
                .foregroundColor(MellowTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

private struct SettingsToggleRow: View {
    let icon: String
    let title: String
    var subtitle: String?
    var tint: Color = MellowTheme.accent
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: MellowTheme.Spacing.md) {
            SettingsRowIcon(icon: icon, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.mellowBody)
                    .foregroundColor(MellowTheme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.mellowCaption)
                        .foregroundColor(MellowTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(tint)
        }
    }
}

private struct HealthExportRow: View {
    @ObservedObject var health: HealthKitBridge
    @State private var requesting = false

    private var isOn: Binding<Bool> {
        Binding(
            get: { health.exportEnabled },
            set: { newValue in
                health.exportEnabled = newValue
                if newValue && !health.isAuthorized && health.isAvailable {
                    requesting = true
                    Task {
                        await health.requestAuthorization()
                        requesting = false
                    }
                }
            }
        )
    }

    private var statusText: String {
        if !health.isAvailable { return "Not available on this device" }
        if !health.exportEnabled { return "Write HR, HRV, SpO₂ & temp to Health" }
        if requesting { return "Requesting access…" }
        return health.isAuthorized ? "Connected. Writing to Health."
                                   : "Tap to allow access in Health"
    }

    private var statusTint: Color {
        if !health.isAvailable { return MellowTheme.textTertiary }
        if health.exportEnabled && health.isAuthorized { return MellowTheme.good }
        return MellowTheme.textTertiary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: MellowTheme.Spacing.md) {
                SettingsRowIcon(icon: "heart.fill", tint: MellowTheme.heartRate)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple Health export")
                        .font(.mellowBody)
                        .foregroundColor(MellowTheme.textPrimary)
                    Text(statusText)
                        .font(.mellowCaption)
                        .foregroundColor(statusTint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if requesting {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(MellowTheme.heartRate)
                } else {
                    Toggle("", isOn: isOn)
                        .labelsHidden()
                        .tint(MellowTheme.heartRate)
                        .disabled(!health.isAvailable)
                }
            }
            if health.exportEnabled && health.isAuthorized {
                Chip(text: "Authorized", icon: "checkmark.seal.fill",
                     tint: MellowTheme.good)
                    .padding(.leading, 46)
            }
        }
    }
}

private struct SettingsSegmentRow: View {
    let icon: String
    let title: String
    var tint: Color = MellowTheme.accent
    let options: [String]
    @Binding var selectedIndex: Int

    var body: some View {
        HStack(spacing: MellowTheme.Spacing.md) {
            SettingsRowIcon(icon: icon, tint: tint)
            Text(title)
                .font(.mellowBody)
                .foregroundColor(MellowTheme.textPrimary)
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                ForEach(Array(options.enumerated()), id: \.offset) { idx, opt in
                    Text(opt)
                        .font(.mellowCaption)
                        .foregroundColor(idx == selectedIndex ? MellowTheme.textInverse
                                                              : MellowTheme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(idx == selectedIndex ? tint : Color.clear)
                        )
                        .onTapGesture {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                selectedIndex = idx
                            }
                        }
                }
            }
            .padding(3)
            .background(Capsule().fill(MellowTheme.fill))
        }
    }
}

private struct SettingsLinkRow: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: MellowTheme.Spacing.md) {
                SettingsRowIcon(icon: icon, tint: MellowTheme.textSecondary)
                Text(title)
                    .font(.mellowBody)
                    .foregroundColor(MellowTheme.textPrimary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(MellowTheme.textTertiary)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsRowIcon: View {
    let icon: String
    let tint: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(tint.opacity(0.16))
                .frame(width: 34, height: 34)
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(tint)
        }
    }
}

private struct SettingsButton: View {
    let title: String
    let icon: String
    var tint: Color = MellowTheme.accent
    var destructive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                Text(title)
                    .font(.mellowCaption)
            }
            .foregroundColor(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: MellowTheme.Radius.sm, style: .continuous)
                    .fill(tint.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: MellowTheme.Radius.sm, style: .continuous)
                            .strokeBorder(tint.opacity(destructive ? 0.35 : 0.0), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Share sheet

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

