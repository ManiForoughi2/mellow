import SwiftUI

// MARK: - ConnectScreen

struct ConnectScreen: View {

    @EnvironmentObject private var store: RingStore
    @EnvironmentObject private var connectController: ConnectController

    @State private var ringPulse = false
    @State private var ringSweep: Double = 0.0

    private var phase: ConnectPhase { ConnectPhase(connectController.phase) }

    private var isIntro: Bool { phase == .intro }

    var body: some View {
        ZStack {
            MellowTheme.screenBackground.ignoresSafeArea()
            ConnectAmbientGlow().allowsHitTesting(false)

            ScrollView {
                VStack(spacing: MellowTheme.Spacing.xl) {
                    hero
                    if isIntro {
                        stepsSection
                    } else {
                        ConnectStatusView(phase: phase,
                                          statusLine: store.statusLine,
                                          failureMessage: connectController.failureMessage)
                    }
                    ctaSection
                }
                .padding(.horizontal, MellowTheme.Spacing.lg)
                .padding(.top, MellowTheme.Spacing.xl)
                .padding(.bottom, MellowTheme.Spacing.xxl)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: phase)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                ringPulse = true
            }
            withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) {
                ringSweep = 1.0
            }
        }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: MellowTheme.Spacing.xl) {
            ConnectHeroRing(pulse: ringPulse, sweep: ringSweep)
                .frame(width: 196, height: 196)

            VStack(spacing: MellowTheme.Spacing.sm) {
                Text("Mellow")
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                    .foregroundStyle(MellowTheme.accentGradient)

                Text("Your ring. Your data. No subscription.")
                    .font(.mellowBody)
                    .foregroundColor(MellowTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Steps

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: MellowTheme.Spacing.lg) {
            SectionHeader(title: "How it works",
                          subtitle: "Five steps to claim your ring")

            VStack(spacing: MellowTheme.Spacing.md) {
                ForEach(Array(ConnectStep.all.enumerated()), id: \.element.id) { idx, step in
                    ConnectStepRow(index: idx + 1, step: step)
                }
            }

            ConnectProgressDots(total: ConnectStep.all.count, active: -1)
                .padding(.top, MellowTheme.Spacing.xs)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: CTA

    private var ctaSection: some View {
        VStack(spacing: MellowTheme.Spacing.md) {
            Button {
                primaryAction()
            } label: {
                HStack(spacing: 8) {
                    if connectController.isWorking {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(MellowTheme.textInverse)
                            .scaleEffect(0.85)
                    } else {
                        Image(systemName: primaryIcon)
                            .font(.system(size: 15, weight: .bold))
                    }
                    Text(primaryTitle)
                        .font(.mellowHeadline)
                }
                .foregroundColor(MellowTheme.textInverse)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Capsule().fill(MellowTheme.accentGradient))
                .shadow(color: MellowTheme.accent.opacity(0.35), radius: 14, y: 6)
            }
            .buttonStyle(.plain)
            .disabled(connectController.isWorking)

            // exactly one secondary action chosen by state so nothing stacks:
            // working -> Cancel, failed -> reset key & re-claim
            secondaryAction
        }
    }

    @ViewBuilder
    private var secondaryAction: some View {
        if connectController.isWorking {
            Button { connectController.cancel() } label: {
                Text("Cancel")
                    .font(.mellowCaption).foregroundColor(MellowTheme.textTertiary)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        } else if case .failed = connectController.phase {
            // two escapes from a failed/stuck attempt, never a dead end
            VStack(spacing: 4) {
                Button { connectController.resetAndReclaim() } label: {
                    Text("Reset key & re-claim")
                        .font(.mellowCaption).foregroundColor(MellowTheme.danger)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                Button { connectController.startOver() } label: {
                    Text("Start over")
                        .font(.mellowCaption).foregroundColor(MellowTheme.textTertiary)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var primaryTitle: String {
        switch connectController.phase {
        case .idle:         return "Claim My Ring"
        case .scanning:     return "Searching…"
        case .provisioning: return "Provisioning…"
        case .handshaking:  return "Authenticating…"
        case .streaming:    return "Streaming live"
        case .failed:       return "Try Again"
        }
    }

    private var primaryIcon: String {
        switch connectController.phase {
        case .idle:      return "sparkles"
        case .streaming: return "checkmark.seal.fill"
        case .failed:    return "arrow.clockwise"
        default:         return "dot.radiowaves.left.and.right"
        }
    }

    private func primaryAction() {
        switch connectController.phase {
        case .idle, .failed:
            connectController.claim()
        case .streaming:
            break   // RootView dismisses cover once connected
        default:
            break   // working, button disabled
        }
    }
}

// MARK: - Visual connection phase

// mirrors ConnectController.Phase plus pre-claim .intro state
enum ConnectPhase: Int, CaseIterable {
    case intro, scanning, provisioning, handshaking, streaming, failed

    init(_ phase: ConnectController.Phase) {
        switch phase {
        case .idle:         self = .intro
        case .scanning:     self = .scanning
        case .provisioning: self = .provisioning
        case .handshaking:  self = .handshaking
        case .streaming:    self = .streaming
        case .failed:       self = .failed
        }
    }

    var title: String {
        switch self {
        case .intro:        return "Ready"
        case .scanning:     return "Scanning for your ring"
        case .provisioning: return "Provisioning your key"
        case .handshaking:  return "Authenticating"
        case .streaming:    return "Streaming live"
        case .failed:       return "Couldn’t connect"
        }
    }

    var subtitle: String {
        switch self {
        case .intro:        return "Tap claim to begin."
        case .scanning:     return "Make sure your ring is on the charger nearby."
        case .provisioning: return "Mellow is writing its own private key to the ring."
        case .handshaking:  return "Establishing a secure, encrypted session…"
        case .streaming:    return "This ring is yours now. No account, no cloud."
        case .failed:       return "Let’s try that again."
        }
    }

    var icon: String {
        switch self {
        case .intro:        return "sparkles"
        case .scanning:     return "dot.radiowaves.left.and.right"
        case .provisioning: return "key.fill"
        case .handshaking:  return "lock.shield.fill"
        case .streaming:    return "waveform.path.ecg"
        case .failed:       return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .intro:        return MellowTheme.accent
        case .scanning:     return MellowTheme.spo2
        case .provisioning: return MellowTheme.sleep
        case .handshaking:  return MellowTheme.strain
        case .streaming:    return MellowTheme.good
        case .failed:       return MellowTheme.danger
        }
    }

    // lit progress dot index (intro/failed = none)
    // order: scanning -> provisioning -> handshaking -> streaming
    var progressIndex: Int {
        switch self {
        case .intro, .failed: return -1
        default:              return rawValue - 1
        }
    }

    static var progressSteps: Int { 4 }
}

// MARK: - Steps model

private struct ConnectStep: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let detail: String
    let tint: Color

    static let all: [ConnectStep] = [
        ConnectStep(icon: "arrow.counterclockwise.circle.fill",
                    title: "Factory-reset your ring",
                    detail: "Clear any previous owner so Mellow can take over.",
                    tint: MellowTheme.temperature),
        ConnectStep(icon: "minus.circle.fill",
                    title: "Forget the ring in iOS Bluetooth",
                    detail: "Settings → Bluetooth → tap ⓘ by your ring → Forget This Device. Clears the stale pairing iOS still holds.",
                    tint: MellowTheme.danger),
        ConnectStep(icon: "bolt.fill",
                    title: "Put it on the charger",
                    detail: "On the charger the ring advertises and stays awake.",
                    tint: MellowTheme.strain),
        ConnectStep(icon: "key.fill",
                    title: "Mellow writes its own key",
                    detail: "A private auth key, written over Bluetooth. Yours alone.",
                    tint: MellowTheme.sleep),
        ConnectStep(icon: "waveform.path.ecg",
                    title: "Stream live",
                    detail: "Heart rate, HRV, SpO₂ and temperature in real time.",
                    tint: MellowTheme.heartRate)
    ]
}

private struct ConnectStepRow: View {
    let index: Int
    let step: ConnectStep

    var body: some View {
        SurfaceCard(cornerRadius: MellowTheme.Radius.md, padding: MellowTheme.Spacing.md) {
            HStack(spacing: MellowTheme.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(step.tint.opacity(0.16))
                        .frame(width: 44, height: 44)
                    Image(systemName: step.icon)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(step.tint)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(step.title)
                        .font(.mellowHeadline)
                        .foregroundColor(MellowTheme.textPrimary)
                    Text(step.detail)
                        .font(.mellowCaption)
                        .foregroundColor(MellowTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Text("\(index)")
                    .font(.mellowLabel)
                    .foregroundColor(MellowTheme.textTertiary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(MellowTheme.fill))
            }
        }
    }
}

// MARK: - Status view

private struct ConnectStatusView: View {
    let phase: ConnectPhase
    let statusLine: String
    // set when phase == .failed, actionable reason
    var failureMessage: String?

    var body: some View {
        VStack(spacing: MellowTheme.Spacing.lg) {
            ZStack {
                Circle()
                    .stroke(phase.tint.opacity(0.18), lineWidth: 2)
                    .frame(width: 132, height: 132)

                switch phase {
                case .streaming:
                    Image(systemName: "checkmark")
                        .font(.system(size: 46, weight: .black))
                        .foregroundColor(phase.tint)
                        .transition(.scale.combined(with: .opacity))
                case .failed:
                    Image(systemName: phase.icon)
                        .font(.system(size: 40, weight: .bold))
                        .foregroundColor(phase.tint)
                        .transition(.scale.combined(with: .opacity))
                default:
                    ConnectSpinner(tint: phase.tint)
                        .frame(width: 96, height: 96)
                    Image(systemName: phase.icon)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundColor(phase.tint)
                }
            }

            VStack(spacing: 6) {
                Text(phase.title)
                    .font(.mellowTitle)
                    .foregroundColor(MellowTheme.textPrimary)
                Text(failureMessage ?? phase.subtitle)
                    .font(.mellowBody)
                    .foregroundColor(phase == .failed ? MellowTheme.textPrimary : MellowTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ConnectProgressDots(total: ConnectPhase.progressSteps,
                                active: phase.progressIndex)

            SurfaceCard(cornerRadius: MellowTheme.Radius.md, padding: MellowTheme.Spacing.md) {
                HStack(spacing: 8) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(MellowTheme.textTertiary)
                    Text(statusLine)
                        .font(.mellowCaption)
                        .foregroundColor(MellowTheme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Decorative pieces

private struct ConnectHeroRing: View {
    let pulse: Bool
    let sweep: Double

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(colors: [MellowTheme.accent.opacity(0.22), .clear],
                                   center: .center, startRadius: 4, endRadius: 120)
                )
                .scaleEffect(pulse ? 1.08 : 0.92)

            RingGauge(progress: 1.0,
                      lineWidth: 10,
                      gradient: AngularGradient(
                        colors: [MellowTheme.accent.opacity(0.25),
                                 MellowTheme.accentSoft.opacity(0.25),
                                 MellowTheme.accent.opacity(0.25)],
                        center: .center),
                      trackColor: MellowTheme.fill) { EmptyView() }

            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(MellowTheme.accentGradient,
                        style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(sweep * 360))
                .padding(5)

            Circle()
                .strokeBorder(MellowTheme.stroke, lineWidth: 1)
                .padding(26)

            Image(systemName: "circle.circle")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundColor(MellowTheme.accentSoft)
        }
    }
}

private struct ConnectSpinner: View {
    let tint: Color
    @State private var spin = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(
                AngularGradient(colors: [tint.opacity(0.0), tint], center: .center),
                style: StrokeStyle(lineWidth: 5, lineCap: .round)
            )
            .rotationEffect(.degrees(spin ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                    spin = true
                }
            }
    }
}

// active is highlighted index (-1 = none)
private struct ConnectProgressDots: View {
    let total: Int
    let active: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<max(total, 0), id: \.self) { i in
                Capsule()
                    .fill(i <= active ? MellowTheme.accent : MellowTheme.fill)
                    .frame(width: i == active ? 22 : 8, height: 8)
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: active)
            }
        }
    }
}

private struct ConnectAmbientGlow: View {
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Circle()
                    .fill(MellowTheme.accent.opacity(0.16))
                    .frame(width: 320, height: 320)
                    .blur(radius: 90)
                    .position(x: geo.size.width * 0.2, y: geo.size.height * 0.12)
                Circle()
                    .fill(MellowTheme.sleep.opacity(0.12))
                    .frame(width: 300, height: 300)
                    .blur(radius: 100)
                    .position(x: geo.size.width * 0.85, y: geo.size.height * 0.85)
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

// MARK: - Previews

