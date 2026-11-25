import Foundation
import UIKit

/// Settings kept on the device. Everything else is configured from Home
/// Assistant and sent over the connection.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// Port the Wyoming server listens on. Home Assistant learns it from the
    /// network announcement, so it only matters if it clashes with something.
    static let defaultPort: UInt16 = 10800

    private let defaults = UserDefaults.standard

    /// Stable id used in the network announcement name, so Home Assistant
    /// recognises the device after renames and restarts.
    let deviceId: String

    @Published var deviceName: String { didSet { defaults.set(deviceName, forKey: "deviceName") } }
    @Published var port: UInt16 { didSet { defaults.set(Int(port), forKey: "port") } }
    /// Used when Home Assistant doesn't send its own URL (no internal URL set).
    @Published var haURLOverride: String { didSet { defaults.set(haURLOverride, forKey: "haURLOverride") } }
    /// Dashboard path used when Home Assistant doesn't send one.
    @Published var dashboardOverride: String { didSet { defaults.set(dashboardOverride, forKey: "dashboardOverride") } }
    /// Echo cancellation on the microphone. Helps when the iPad plays audio
    /// while listening, but lowers playback volume on some models.
    @Published var echoCancellation: Bool { didSet { defaults.set(echoCancellation, forKey: "echoCancellation") } }
    @Published var setupComplete: Bool { didSet { defaults.set(setupComplete, forKey: "setupComplete") } }

    private init() {
        if let id = defaults.string(forKey: "deviceId") {
            deviceId = id
        } else {
            let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
            deviceId = String(id)
            defaults.set(deviceId, forKey: "deviceId")
        }
        deviceName = defaults.string(forKey: "deviceName") ?? UIDevice.current.name
        let storedPort = defaults.integer(forKey: "port")
        port = (1...65535).contains(storedPort) ? UInt16(storedPort) : Self.defaultPort
        haURLOverride = defaults.string(forKey: "haURLOverride") ?? ""
        dashboardOverride = defaults.string(forKey: "dashboardOverride") ?? ""
        echoCancellation = defaults.object(forKey: "echoCancellation") as? Bool ?? true
        setupComplete = defaults.bool(forKey: "setupComplete")
    }

    /// Name the device announces on the network; Home Assistant uses it as
    /// part of the integration's unique id.
    var serviceName: String { "vaca-ios-\(deviceId)" }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}
