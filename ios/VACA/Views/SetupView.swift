import SwiftUI

/// First-run guide.
struct SetupView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var satellite = Satellite.shared

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Turn this iPad into a smart display for Home Assistant.")
                        .font(.title3)

                    step(1, "Install the VACA integration",
                         "In Home Assistant, install View Assist Companion App from HACS and restart.")
                    step(2, "Add this iPad",
                         "Keep this app open. Home Assistant finds it on your network: Settings → Devices & services → Discovered → VACA. Allow Local Network access here if asked.")
                    step(3, "Set up the wake word",
                         "On iOS, Home Assistant listens for the wake word. Add the openWakeWord add-on (or another wake word service) and pick a wake word in your voice assistant's settings. The microphone button always works too.")
                    step(4, "Keep it on screen",
                         "Plug the iPad in. To lock it to this app, turn on Guided Access (iPad Settings → Accessibility → Guided Access), then triple-click the top or Home button here.")

                    HStack {
                        Image(systemName: satellite.connected ? "checkmark.circle.fill" : "hourglass")
                            .foregroundColor(satellite.connected ? Color.green : Color.secondary)
                        Text(satellite.connected ? "Connected to Home Assistant" : "Waiting for Home Assistant…")
                    }
                    .font(.headline)

                    Button {
                        settings.setupComplete = true
                    } label: {
                        Text("Done").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(28)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Welcome to VACA")
        }
        .navigationViewStyle(.stack)
        .interactiveDismissDisabled()
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.headline)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.accentColor.opacity(0.2)))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
        }
    }
}
