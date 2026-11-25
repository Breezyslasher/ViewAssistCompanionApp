import Combine
import Foundation
import UIKit
import VACACore

enum AssistPhase {
    case idle, listening, thinking, speaking
}

enum WebCommand {
    case reload
    case load(URL)
}

/// The device side of the VACA integration: answers Home Assistant's
/// connection, streams the microphone for wake word detection, plays
/// responses and media, and applies the settings and actions HA sends.
///
/// Everything here runs on the main queue (the network and audio callbacks
/// hop to it), so there is no locking.
final class Satellite: ObservableObject {
    static let shared = Satellite()

    // MARK: State shown in the UI

    @Published private(set) var serverStatus = "Starting…"
    @Published private(set) var connected = false
    @Published private(set) var phase: AssistPhase = .idle
    @Published private(set) var transcript = ""
    @Published private(set) var response = ""
    @Published private(set) var errorText: String?
    @Published private(set) var toast: String?
    @Published private(set) var dashboardURL: URL?
    @Published private(set) var screenOn = true
    @Published private(set) var darkMode: Bool?
    @Published private(set) var pageZoom: CGFloat = 1
    @Published private(set) var micAllowed: Bool?

    let webCommands = PassthroughSubject<WebCommand, Never>()

    // MARK: Internals

    private let settings = AppSettings.shared
    private let server = WyomingServer()
    private let audio = AudioController()
    private let media = MediaController()

    private var satelliteConnection: WyomingConnection?
    /// Address Home Assistant connected from, to find its web UI if needed.
    private var haHost: String?
    /// Settings Home Assistant sent (custom_settings in the integration).
    private var haSettings: [String: Any] = [:]

    private var streaming = false
    private var micTimestamp = 0
    private var pipelineRunning = false
    private var manualRunPending = false
    private var muted = false

    private var wakeSoundEnabled = true
    private var screenAlwaysOn = true
    private var screenTimeout: TimeInterval = 60
    private var brightness: CGFloat = UIScreen.main.brightness
    private var currentPath = ""

    private var idleTimer: Timer?
    private var statusTimer: Timer?
    private var toastTimer: Timer?
    private var errorTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    // MARK: Lifecycle

    func start() {
        UIApplication.shared.isIdleTimerDisabled = true
        UIDevice.current.isBatteryMonitoringEnabled = true

        audio.echoCancellation = settings.echoCancellation
        audio.onMicAudio = { [weak self] pcm in self?.sendMic(pcm) }
        audio.onResponsePlayed = { [weak self] in self?.responsePlayed() }
        media.onStateChange = { [weak self] _ in self?.sendStatus() }

        server.onEvent = { [weak self] connection, event in self?.handle(event, from: connection) }
        server.onClose = { [weak self] connection in self?.connectionClosed(connection) }
        server.onStateChange = { [weak self] status in
            self?.serverStatus = status
            Log.shared.add(status)
        }
        server.start(port: settings.port, serviceName: settings.serviceName)

        AudioController.requestPermission { [weak self] granted in
            guard let self else { return }
            self.micAllowed = granted
            if granted {
                // Keep the engine running even while disconnected: with the
                // audio background mode it is what keeps the app awake
                // (and reconnectable) when the screen locks.
                self.audio.start()
            } else {
                Log.shared.add("Microphone permission denied")
            }
        }

        let center = NotificationCenter.default
        for name in [UIDevice.batteryLevelDidChangeNotification,
                     UIDevice.batteryStateDidChangeNotification,
                     UIDevice.orientationDidChangeNotification] {
            center.publisher(for: name)
                .debounce(for: .seconds(1), scheduler: RunLoop.main)
                .sink { [weak self] _ in self?.sendStatus() }
                .store(in: &cancellables)
        }
        statusTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.sendStatus()
        }

        updateDashboardURL()
        resetIdleTimer()
    }

    /// Restart the server after the name or port changes in Settings.
    func restartServer() {
        satelliteConnection = nil
        connected = false
        streaming = false
        server.start(port: settings.port, serviceName: settings.serviceName)
    }

    func applyLocalSettings() {
        audio.echoCancellation = settings.echoCancellation
        if audio.isRunning { audio.restart() }
        updateDashboardURL()
    }

    // MARK: Events from Home Assistant

    private func handle(_ event: WyomingEvent, from connection: WyomingConnection) {
        let isSatellite = connection === satelliteConnection

        switch event.type {
        case EventType.describe:
            connection.send(SatelliteMessages.info(
                name: settings.deviceName,
                appVersion: AppSettings.appVersion,
                area: haSettings["area"] as? String
            ))

        case EventType.capabilities:
            connection.send(SatelliteMessages.capabilities(
                appVersion: AppSettings.appVersion,
                osVersion: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
                model: Self.modelIdentifier,
                hasBattery: UIDevice.current.batteryState != .unknown
            ))

        case EventType.ping:
            connection.send(SatelliteMessages.pong(text: event.string("text")))

        case EventType.runSatellite:
            becomeSatellite(connection)

        case EventType.pauseSatellite where isSatellite:
            Log.shared.add("Home Assistant paused the satellite")
            streaming = false
            pipelineRunning = false
            setPhase(.idle)

        case EventType.detection where isSatellite:
            wakeDetected()

        case EventType.transcribe where isSatellite:
            if phase == .idle { setPhase(.listening) }

        case EventType.voiceStopped where isSatellite:
            setPhase(.thinking)

        case EventType.transcript where isSatellite:
            transcript = event.string("text") ?? ""
            setPhase(.thinking)

        case EventType.synthesize where isSatellite:
            response = event.string("text") ?? ""

        case EventType.audioStart where isSatellite:
            setPhase(.speaking)
            media.setDucked(true)
            audio.beginResponse(rate: event.int("rate") ?? 22_050, channels: event.int("channels") ?? 1)

        case EventType.audioChunk where isSatellite:
            if let payload = event.payload {
                audio.appendResponse(payload, channels: event.int("channels") ?? 1)
            }

        case EventType.audioStop where isSatellite:
            audio.endResponse()

        case EventType.error where isSatellite:
            let text = event.string("text") ?? "Something went wrong"
            Log.shared.add("Pipeline error: \(text) (\(event.string("code") ?? "-"))")
            // Wake word stage ending without a wake word is routine.
            if event.string("code") != "wake-word-timeout" { showError(text) }

        case EventType.pipelineEnded where isSatellite:
            pipelineEnded()

        case EventType.customEvent:
            if let custom = IncomingCustomEvent(event) { handleCustom(custom) }

        case EventType.pong, EventType.detect, EventType.voiceStarted, EventType.handled:
            break

        default:
            if !event.type.hasPrefix("timer-") {
                Log.shared.add("Unhandled event: \(event.type)")
            }
        }
    }

    private func becomeSatellite(_ connection: WyomingConnection) {
        if let old = satelliteConnection, old !== connection { old.close() }
        satelliteConnection = connection
        haHost = connection.remoteHost
        connected = true
        streaming = true
        pipelineRunning = false
        manualRunPending = false
        Log.shared.add("Home Assistant connected from \(haHost ?? "?")")
        if micAllowed == true, !audio.isRunning { audio.start() }
        updateDashboardURL()
        startWakePipeline()
        sendStatus()
    }

    private func connectionClosed(_ connection: WyomingConnection) {
        guard connection === satelliteConnection else { return }
        Log.shared.add("Home Assistant disconnected")
        satelliteConnection = nil
        connected = false
        streaming = false
        pipelineRunning = false
        manualRunPending = false
        audio.cancelResponse()
        setPhase(.idle)
    }

    // MARK: Voice pipeline

    /// Stream the mic and let Home Assistant listen for the wake word.
    private func startWakePipeline() {
        guard streaming, !muted, !pipelineRunning, let connection = satelliteConnection else { return }
        pipelineRunning = true
        connection.send(SatelliteMessages.runPipeline(start: "wake"))
    }

    private func sendMic(_ pcm: Data) {
        guard streaming, !muted, let connection = satelliteConnection else { return }
        connection.send(SatelliteMessages.micChunk(pcm, timestampMs: micTimestamp))
        micTimestamp += PCM.milliseconds(bytes: pcm.count, rate: MicFormat.rate)
    }

    private func wakeDetected() {
        transcript = ""
        response = ""
        setPhase(.listening)
        screenWake()
        media.setDucked(true)
        if wakeSoundEnabled { audio.playWakeChime() }
    }

    /// Start listening without the wake word: the on-screen button, or the
    /// Wake button / action in Home Assistant.
    func talkNow() {
        screenWake()
        guard let connection = satelliteConnection, streaming else { return }
        wakeDetected()
        if pipelineRunning {
            // End the wake word stage first; the listening run starts when
            // HA reports the pipeline ended (or after a short wait).
            manualRunPending = true
            connection.send(SatelliteMessages.audioStop(timestampMs: micTimestamp))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.manualRunPending else { return }
                self.manualRunPending = false
                self.startListeningRun()
            }
        } else {
            startListeningRun()
        }
    }

    private func startListeningRun() {
        guard let connection = satelliteConnection else { return }
        pipelineRunning = true
        connection.send(SatelliteMessages.runPipeline(start: "asr"))
    }

    private func pipelineEnded() {
        pipelineRunning = false
        if manualRunPending {
            manualRunPending = false
            startListeningRun()
            return
        }
        if phase == .speaking {
            // Restart once the response has finished playing.
            return
        }
        if phase != .idle { setPhase(.idle) }
        media.setDucked(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.startWakePipeline()
        }
    }

    private func responsePlayed() {
        satelliteConnection?.send(SatelliteMessages.played())
        media.setDucked(false)
        setPhase(.idle)
        resetIdleTimer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.startWakePipeline()
        }
    }

    private func setPhase(_ newPhase: AssistPhase) {
        guard phase != newPhase else { return }
        phase = newPhase
        if newPhase != .idle { resetIdleTimer() }
    }

    // MARK: Settings and actions from Home Assistant

    private func handleCustom(_ event: IncomingCustomEvent) {
        switch event.eventType {
        case CustomEventType.settings:
            let incoming = event.settings
            haSettings.merge(incoming) { _, new in new }
            for (key, value) in incoming { applySetting(key, value) }
        case CustomEventType.action:
            if let action = event.action { handleAction(action, event.payload) }
        default:
            Log.shared.add("Unhandled custom event: \(event.eventType)")
        }
    }

    private func applySetting(_ key: String, _ value: Any) {
        switch key {
        case "ha_url", "ha_port", "ha_dashboard":
            updateDashboardURL()
        case "screen_brightness":
            if let v = Self.number(value) {
                brightness = CGFloat(max(0, min(100, v)) / 100)
                if screenOn { UIScreen.main.brightness = brightness }
            }
        case "screen_on":
            if let on = Self.bool(value) { on ? screenWake() : screenSleep() }
        case "screen_always_on":
            if let on = Self.bool(value) { screenAlwaysOn = on; resetIdleTimer() }
        case "screen_timeout":
            if let v = Self.number(value), v > 0 { screenTimeout = v; resetIdleTimer() }
        case "dark_mode":
            darkMode = Self.bool(value)
        case "zoom_level":
            // HA sends round(zoom * 100) + 60, or 0 for the default.
            if let v = Self.number(value) {
                pageZoom = v > 0 ? CGFloat(max(0.3, min(3, (v - 60) / 100))) : 1
            }
        case "music_volume":
            if let v = Self.number(value) { media.musicVolume = Float(v / 10) }
        case "notification_volume":
            if let v = Self.number(value) {
                audio.responseVolume = Float(v / 10)
                media.announceVolume = Float(v / 10)
            }
        case "ducking_volume":
            if let v = Self.number(value) { media.duckingVolume = Float(v / 10) }
        case "mic_gain":
            if let v = Self.number(value) { audio.micGainDb = Float(v) }
        case "wake_word_sound":
            wakeSoundEnabled = (value as? String)?.lowercased() != "none"
        case "mute":
            if let on = Self.bool(value) {
                muted = on
                if !on { startWakePipeline() }
            }
        default:
            break
        }
    }

    private func handleAction(_ action: String, _ payload: Any?) {
        let body = payload as? [String: Any] ?? [:]
        switch action {
        case "wake":
            talkNow()
        case "interrupt":
            audio.cancelResponse()
        case "refresh":
            webCommands.send(.reload)
        case "navigate":
            let path = body["path"] as? String ?? payload as? String ?? ""
            if let url = resolve(path) { webCommands.send(.load(url)) }
            screenWake()
        case "screen-wake":
            screenWake()
        case "screen-sleep":
            screenSleep()
        case "toast-message":
            let text = body["message"] as? String ?? body["text"] as? String ?? payload as? String
            if let text { showToast(text) }
        case "play-media":
            guard let urlText = body["url"] as? String, let url = resolve(urlText) else { return }
            let volume = Self.number(body["volume"] as Any).map { Float($0 / 100) }
            media.play(url: url, volume: volume, announce: Self.bool(body["announce"] as Any) ?? false)
        case "play":
            media.resume(volume: Self.number(body["volume"] as Any).map { Float($0 / 100) })
        case "pause":
            media.pause()
        case "stop":
            media.stop()
        case "set-volume":
            if let v = Self.number(body["volume"] as Any) { media.musicVolume = Float(v / 100) }
        case "get-logs":
            var event = SatelliteMessages.custom(CustomEventType.logs, [:])
            event.payload = Data(Log.shared.text.utf8)
            satelliteConnection?.send(event)
        default:
            Log.shared.add("Action not supported on iOS yet: \(action)")
        }
    }

    // MARK: Dashboard

    /// Base URL of Home Assistant's web UI.
    private var haBaseURL: String? {
        if let url = haSettings["ha_url"] as? String, !url.isEmpty {
            return url.hasSuffix("/") ? String(url.dropLast()) : url
        }
        let override = settings.haURLOverride.trimmingCharacters(in: .whitespaces)
        if !override.isEmpty { return override.hasSuffix("/") ? String(override.dropLast()) : override }
        guard let host = haHost else { return nil }
        let port = Self.number(haSettings["ha_port"] as Any).map { Int($0) } ?? 8123
        return "http://\(host):\(port)"
    }

    /// Absolute URLs pass through; paths are joined to Home Assistant's URL.
    private func resolve(_ pathOrURL: String) -> URL? {
        if pathOrURL.hasPrefix("http://") || pathOrURL.hasPrefix("https://") { return URL(string: pathOrURL) }
        guard let base = haBaseURL else { return nil }
        let path = pathOrURL.hasPrefix("/") ? pathOrURL : "/" + pathOrURL
        return URL(string: base + path)
    }

    private func updateDashboardURL() {
        let fromHA = (haSettings["ha_dashboard"] as? String) ?? ""
        let path = fromHA.isEmpty ? settings.dashboardOverride : fromHA
        let url = resolve(path)
        if url != dashboardURL { dashboardURL = url }
    }

    /// The web view reports where it is, for the current path sensor.
    func webPathChanged(_ path: String) {
        guard path != currentPath else { return }
        currentPath = path
        sendStatus()
    }

    // MARK: Screen

    /// iOS apps can't turn the screen off, so "off" is brightness zero with
    /// a black cover; touching it or any activity turns it back on.
    func screenSleep() {
        guard screenOn else { return }
        screenOn = false
        UIScreen.main.brightness = 0
        sendStatus()
    }

    func screenWake() {
        resetIdleTimer()
        guard !screenOn else { return }
        screenOn = true
        UIScreen.main.brightness = brightness
        sendStatus()
    }

    /// Any touch on the screen.
    func userActivity() {
        screenWake()
    }

    private func resetIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = nil
        guard !screenAlwaysOn else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: screenTimeout, repeats: false) { [weak self] _ in
            guard let self, self.phase == .idle else { return }
            self.screenSleep()
        }
    }

    // MARK: Toast and errors

    private func showToast(_ text: String) {
        toast = text
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in self?.toast = nil }
    }

    private func showError(_ text: String) {
        errorText = text
        errorTimer?.invalidate()
        errorTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in self?.errorText = nil }
    }

    // MARK: Status

    private func sendStatus() {
        guard let connection = satelliteConnection else { return }
        let device = UIDevice.current
        var sensors: [String: Any] = [
            "orientation": UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.interfaceOrientation }
                .first.map { $0.isLandscape ? "landscape" : "portrait" } ?? "unknown",
            "current_path": currentPath,
        ]
        if device.batteryState != .unknown {
            sensors["battery_level"] = Int((device.batteryLevel * 100).rounded())
            sensors["battery_charging"] = device.batteryState == .charging || device.batteryState == .full
        }
        connection.send(SatelliteMessages.status(sensors: sensors, mediaPlaying: media.isPlaying))
    }

    // MARK: Helpers

    static func number(_ value: Any) -> Double? {
        switch value {
        case let v as Double: return v
        case let v as Int: return Double(v)
        case let v as String: return Double(v)
        case let v as Bool: return v ? 1 : 0
        default: return nil
        }
    }

    static func bool(_ value: Any) -> Bool? {
        switch value {
        case let v as Bool: return v
        case let v as Int: return v != 0
        case let v as String: return ["true", "on", "1", "yes"].contains(v.lowercased())
        default: return nil
        }
    }

    /// Hardware model, e.g. "iPad13,1".
    static let modelIdentifier: String = {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }()
}
