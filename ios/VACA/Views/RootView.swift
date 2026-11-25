import SwiftUI

struct RootView: View {
    @ObservedObject private var satellite = Satellite.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let url = satellite.dashboardURL {
                DashboardView(url: url, zoom: satellite.pageZoom, darkMode: satellite.darkMode)
                    .ignoresSafeArea()
            } else {
                WaitingView(showSettings: $showSettings)
            }

            AssistOverlay()

            if let toast = satellite.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.title3)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 14)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 60)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }

            cornerButtons

            if !satellite.screenOn {
                // "Screen off": black, brightness zero. A touch wakes it.
                Color.black
                    .ignoresSafeArea()
                    .onTapGesture { satellite.userActivity() }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: satellite.phase)
        .animation(.easeInOut(duration: 0.25), value: satellite.toast)
        .statusBarHidden(true)
        .modifier(HideHomeIndicator())
        .preferredColorScheme(satellite.darkMode.map { $0 ? ColorScheme.dark : ColorScheme.light })
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: .constant(!settings.setupComplete && !showSettings)) {
            SetupView()
        }
    }

    /// Small, low-contrast buttons so they don't spoil the dashboard:
    /// talk (bottom right) and settings (top right).
    private var cornerButtons: some View {
        VStack {
            HStack {
                Spacer()
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 18))
                        .padding(12)
                        .background(Color.black.opacity(0.25), in: Circle())
                }
                .foregroundStyle(Color.white.opacity(0.5))
            }
            Spacer()
            HStack {
                Spacer()
                Button { satellite.talkNow() } label: {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 22))
                        .padding(16)
                        .background(Color.black.opacity(0.3), in: Circle())
                }
                .foregroundStyle(Color.white.opacity(satellite.connected ? 0.75 : 0.3))
                .disabled(!satellite.connected)
            }
        }
        .padding(16)
    }
}

private struct HideHomeIndicator: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.persistentSystemOverlays(.hidden)
        } else {
            content
        }
    }
}

/// Shown until Home Assistant connects and sends its URL.
private struct WaitingView: View {
    @ObservedObject private var satellite = Satellite.shared
    @Binding var showSettings: Bool

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: satellite.connected ? "checkmark.circle" : "antenna.radiowaves.left.and.right")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text(satellite.connected ? "Connected to Home Assistant" : "Waiting for Home Assistant")
                .font(.title2.bold())
            Text(satellite.connected
                 ? "No dashboard URL yet. Set Home Assistant's internal URL, or enter it in Settings."
                 : "Home Assistant finds this iPad automatically. Look under Settings → Devices & services → Discovered.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            Text(satellite.serverStatus)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
            Button("Settings") { showSettings = true }
                .buttonStyle(.bordered)
        }
        .padding(32)
        .foregroundStyle(.white)
    }
}
