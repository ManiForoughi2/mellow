import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var connect: ConnectController

    // show connect cover until ring claimed; no skip, need a claimed ring for real data
    private var showConnectCover: Bool {
        !model.hasAuthKey && !connect.isConnected
    }

    var body: some View {
        MainTabView()
            .preferredColorScheme(.light)
            .fullScreenCover(isPresented: .constant(showConnectCover)) {
                ConnectScreen().preferredColorScheme(.light)
            }
            .animation(.default, value: connect.isConnected)
            .onAppear {
                // UI-preview mode (Simulator/Maestro): tabs prepopulated, never kick off real BLE claim
                #if DEBUG
                if AppModel.isUIPreview { return }
                #endif
                // already own ring: reconnect silently in background, no cover
                if model.hasAuthKey && connect.phase == .idle {
                    connect.claim()
                }
            }
    }
}

// MARK: - Main tab bar

struct MainTabView: View {
    init() { Self.styleTabBar(); Self.styleNavBar() }

    var body: some View {
        TabView {
            TodayTab()
                .tabItem { Label("Today", systemImage: "sun.max.fill") }

            NavStackScreen { StressScreen() }
                .tabItem { Label("Stress", systemImage: "waveform.path.ecg") }

            NavStackScreen { SleepScreen() }
                .tabItem { Label("Sleep", systemImage: "moon.stars.fill") }

            NavStackScreen { HistoryScreen() }
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
        }
        .tint(MellowTheme.accent)
    }

    private static func styleTabBar() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(MellowTheme.bgRaised)
        appearance.shadowColor = UIColor(MellowTheme.stroke)
        let item = appearance.stackedLayoutAppearance
        item.normal.iconColor = UIColor(MellowTheme.textTertiary)
        item.normal.titleTextAttributes = [.foregroundColor: UIColor(MellowTheme.textTertiary)]
        item.selected.iconColor = UIColor(MellowTheme.accent)
        item.selected.titleTextAttributes = [.foregroundColor: UIColor(MellowTheme.accent)]
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    // opaque nav bar = MellowTheme.bg so scrolled content is masked, not bleeding behind toolbar icons
    private static func styleNavBar() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(MellowTheme.bg)
        appearance.shadowColor = .clear
        appearance.titleTextAttributes = [.foregroundColor: UIColor(MellowTheme.textPrimary)]
        appearance.largeTitleTextAttributes = [.foregroundColor: UIColor(MellowTheme.textPrimary)]
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
    }
}

// own NavigationStack per tab so nav bar masks cleanly on scroll
private struct NavStackScreen<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { NavigationStack { content } }
}

// MARK: - Today tab

private struct TodayTab: View {
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            OverviewScreen()
                .navigationDestination(isPresented: $showSettings) {
                    SettingsScreen().navigationBarTitleDisplayMode(.inline)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showSettings = true } label: {
                            Image(systemName: "gearshape").foregroundColor(MellowTheme.accent)
                        }
                        .accessibilityLabel("Settings")
                    }
                }
        }
    }
}
