import SwiftUI

/// On-device settings. Most settings live in Home Assistant (the device page
/// of the VACA integration); these are the few the iPad needs itself.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var satellite = Satellite.shared
    @ObservedObject private var log = Log.shared

    @State private var name = ""
    @State private var portText = ""
    @State private var haURL = ""
    @State private var dashboard = ""
    @State private var echoCancellation = false

    var body: some View {
        NavigationView {
            Form {
                Section("Status") {
                    LabeledRow("Home Assistant", satellite.connected ? "Connected" : "Not connected")
                    LabeledRow("Server", satellite.serverStatus)
                    LabeledRow("Microphone", micText)
                    LabeledRow("App version", AppSettings.appVersion)
                }

                Section {
                    TextField("Device name", text: $name)
                    TextField("Port", text: $portText)
                        .keyboardType(.numberPad)
                } header: {
                    Text("Device")
                } footer: {
                    Text("The name Home Assistant shows for this iPad. Change the port only if \(AppSettings.defaultPort) is in use.")
                }

                Section {
                    TextField("http://homeassistant.local:8123", text: $haURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    TextField("Dashboard path, e.g. view-assist", text: $dashboard)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                } header: {
                    Text("Dashboard (optional)")
                } footer: {
                    Text("Only needed if Home Assistant doesn't send them. Set the URL in the VACA integration's options, or Home Assistant's internal URL, and it's sent automatically.")
                }

                Section {
                    Toggle("Echo cancellation", isOn: $echoCancellation)
                } header: {
                    Text("Audio")
                } footer: {
                    Text("Helps the wake word work while the iPad is playing sound. Can make playback quieter.")
                }

                Section {
                    Button("Reload dashboard") { satellite.webCommands.send(.reload) }
                    Button("Show setup guide") { settings.setupComplete = false; dismiss() }
                }

                Section("Log") {
                    ScrollView {
                        Text(log.lines.suffix(150).joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 220)
                }
            }
            .navigationTitle("VACA Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear(perform: load)
    }

    private var micText: String {
        switch satellite.micAllowed {
        case .some(true): return "Allowed"
        case .some(false): return "Denied (allow in iPad Settings)"
        case .none: return "Not asked yet"
        }
    }

    private func load() {
        name = settings.deviceName
        portText = String(settings.port)
        haURL = settings.haURLOverride
        dashboard = settings.dashboardOverride
        echoCancellation = settings.echoCancellation
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let newPort = UInt16(portText) ?? settings.port
        let restart = newPort != settings.port

        if !trimmedName.isEmpty { settings.deviceName = trimmedName }
        settings.port = newPort
        settings.haURLOverride = haURL.trimmingCharacters(in: .whitespaces)
        settings.dashboardOverride = dashboard.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        settings.echoCancellation = echoCancellation

        satellite.applyLocalSettings()
        if restart { satellite.restartServer() }
        dismiss()
    }
}

private struct LabeledRow: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }
}
