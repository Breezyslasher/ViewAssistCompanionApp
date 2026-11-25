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

/// The device side of VACA: a port of the Android app's Satellite.kt and
/// WyomingTCPServer.kt. It answers Home Assistant's connection, listens for
/// the wake word on the device, runs voice interactions (AudioPipeline),
/// plays responses, sounds, alarms and media, and applies the settings and
/// actions Home Assistant sends.
///
/// Everything here runs on the main queue except the microphone path, which
/// hops to it.
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
    @Published private(set) var wakeWordPhrase = ""

    let webCommands = PassthroughSubject<WebCommand, Never>()

    // MARK: Parts

    private let settings = AppSettings.shared
    private let server = WyomingServer()
    private let audio = AudioController()
    private let media = MediaController()
    private let sounds = SoundEffects()
    private let wake = WakeWordEngine()

    private var satelliteConnection: WyomingConnection?
    private var haHost: String?
    /// Settings Home Assistant sent (custom_settings in the integration).
    private var haSettings: [String: Any] = [:]
    private var settingsReceived = false

    // MARK: Voice

    private var pipeline: AudioPipeline?
    private var pipelineCount = 0
    private var pipelineWatchdog: Timer?
    /// Microphone audio kept from the wake word until Home Assistant starts
    /// listening, so nothing said straight after the wake word is lost.
    private var preRoll: [Data]?
    private var micStreaming = false
    private var micTimestamp = 0

    private var wakeWord = "hey_jarvis"
    private var wakeThreshold: Float = -1
    private var wakeWordSound = "none"
    private var alarmSound = "default"
    private var continueConversation = false
    private var screenOnWakeWord = true
    private var muted = false
    /// Read on the microphone queue.
    private var stopWordArmed = false

    // MARK: Screen

    private var screenAlwaysOn = true
    private var screenTimeout: TimeInterval = 60
    private var brightness: CGFloat = UIScreen.main.brightness
    private var currentPath = ""

    private var idleTimer: Timer?
    private var statusTimer: Timer?
    private var toastTimer: Timer?
    private var errorTimer: Timer?
    private var settingsTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    // MARK: Lifecycle

    func start() {
        UIApplication.shared.isIdleTimerDisabled = true
        UIDevice.current.isBatteryMonitoringEnabled = true

        audio.echoCancellation = settings.echoCancellation
        audio.onMicAudio = { [weak self] pcm in self?.micAudio(pcm) }
        media.onStateChange = { [weak self] _ in self?.sendStatus() }

        wake.onWakeWord = { [weak self] detection in self?.wakeWordDetected(detection) }
        wake.onStopWord = { [weak self] in self?.stopWordDetected() }
        wake.stopWordActive = { [weak self] in self?.stopWordArmed ?? false }
        configureWakeWord()

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
                // Always on: wake word detection, and with the audio
                // background mode it keeps the app running when locked.
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

    func restartServer() {
        satelliteConnection = nil
        connected = false
        server.start(port: settings.port, serviceName: settings.serviceName)
    }

    func applyLocalSettings() {
        audio.echoCancellation = settings.echoCancellation
        if audio.isRunning { audio.restart() }
        updateDashboardURL()
    }

    // MARK: Connection (WyomingTCPServer.messageHandler)

    private func handle(_ event: WyomingEvent, from connection: WyomingConnection) {
        switch event.type {
        case EventType.ping:
            connection.send(SatelliteMessages.pong(text: event.string("text")))
        case EventType.pong:
            break
        case EventType.describe:
            connection.send(infoEvent())
        case EventType.capabilities:
            connection.send(capabilitiesEvent())
        case EventType.runSatellite:
            becomeSatellite(connection)
        case EventType.pauseSatellite:
            // HA sends this on reload/restart, normally followed by
            // run-satellite; the connection watchdog handles real loss.
            Log.shared.add("Home Assistant paused the satellite")
        default:
            guard connection === satelliteConnection else { return }
            processMessage(event)
        }
    }

    private func infoEvent() -> WyomingEvent {
        SatelliteMessages.info(
            name: settings.deviceName,
            appVersion: AppSettings.appVersion,
            area: haSettings["area"] as? String ?? "",
            activeWakeWord: wakeWord,
            wakeWords: wake.available.map { (WakeWordEngine.engineName, $0.id, $0.manifest.wake_word) }
        )
    }

    private func capabilitiesEvent() -> WyomingEvent {
        SatelliteMessages.capabilities(
            appVersion: AppSettings.appVersion,
            osVersion: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            model: Self.modelIdentifier,
            hasBattery: UIDevice.current.batteryState != .unknown,
            wakeSounds: sounds.wakeSounds.map { ($0.id, $0.name) },
            alarms: sounds.alarms.map { ($0.id, $0.name) }
        )
    }

    private func becomeSatellite(_ connection: WyomingConnection) {
        if let old = satelliteConnection, old !== connection { old.close() }
        satelliteConnection = connection
        haHost = connection.remoteHost
        connected = true
        connection.startKeepAlive()
        Log.shared.add("Home Assistant connected from \(haHost ?? "?")")
        if micAllowed == true, !audio.isRunning { audio.start() }
        updateDashboardURL()
        sendStatus()

        // HA sends all settings after run-satellite; ask again if they don't
        // arrive (Satellite.waitForSettings).
        settingsTimer?.invalidate()
        settingsTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            guard let self, !self.settingsReceived else { return }
            Log.shared.add("No settings from Home Assistant yet; asking")
            self.satelliteConnection?.send(SatelliteMessages.requestSettings())
        }
    }

    private func connectionClosed(_ connection: WyomingConnection) {
        guard connection === satelliteConnection else { return }
        Log.shared.add("Home Assistant disconnected")
        satelliteConnection = nil
        connected = false
        pipeline?.stop()
        pipeline = nil
        audio.stopResponse()
        setPhase(.idle)
    }

    /// Satellite.processMessage
    private func processMessage(_ event: WyomingEvent) {
        if event.type == EventType.customEvent {
            if let custom = IncomingCustomEvent(event) { handleCustom(custom) }
            return
        }
        if let pipeline, pipeline.isActive {
            pipeline.handle(event)
        } else if event.type == EventType.audioStart {
            // An announcement, or a response without our own pipeline.
            startPipeline(.startStreamTTS)
            pipeline?.handle(event)
        } else if event.type == EventType.transcribe {
            // Home Assistant started listening (start conversation).
            startPipeline(.requestedByServer)
            pipeline?.handle(event)
        }
    }

    // MARK: Wake word

    private func configureWakeWord() {
        let word = wakeWord
        let threshold = wakeThreshold
        let muted = self.muted
        wakeWordPhrase = wake.available.first { $0.id == word }?.manifest.wake_word ?? word
        audio.micQueue.async {
            self.wake.muted = muted
            self.wake.configure(wakeWord: word, threshold: threshold)
        }
    }

    /// Microphone audio, on the mic queue.
    private func micAudio(_ pcm: Data) {
        wake.process(pcm)
        DispatchQueue.main.async { self.forwardMic(pcm) }
    }

    private func forwardMic(_ pcm: Data) {
        if micStreaming {
            sendMic(pcm)
        } else if preRoll != nil {
            preRoll?.append(pcm)
            // Keep at most ~5 s.
            if (preRoll?.count ?? 0) > 80 { preRoll?.removeFirst() }
        }
    }

    private func sendMic(_ pcm: Data) {
        guard let connection = satelliteConnection else { return }
        connection.send(SatelliteMessages.micChunk(pcm, timestampMs: micTimestamp))
        micTimestamp += PCM.milliseconds(bytes: pcm.count, rate: MicFormat.rate)
    }

    /// Satellite.handleWakeWordDetection
    private func wakeWordDetected(_ detection: WakeWordDetection) {
        Log.shared.add("Wake word: \(detection.wakeWord) (\(String(format: "%.2f", detection.score)))")
        guard satelliteConnection != nil else {
            showToast("No connection to Home Assistant. Unable to respond to voice command.")
            return
        }
        // A wake word while the device is talking interrupts it.
        if isResponding {
            interruptResponse()
            return
        }
        startWakePipeline()
    }

    /// Wake word heard, or a manual wake.
    private func startWakePipeline() {
        transcript = ""
        response = ""
        if screenOnWakeWord { screenWake() }
        media.setDucked(true)
        sounds.playWakeSound(wakeWordSound)
        preRoll = []
        startPipeline(.wakeWordDetected)
    }

    /// The microphone button, or the Wake button / action in Home Assistant.
    func talkNow() {
        screenWake()
        guard satelliteConnection != nil else { return }
        if isResponding { interruptResponse() }
        startWakePipeline()
    }

    private var isResponding: Bool {
        if audio.isResponding { return true }
        guard let pipeline, pipeline.isActive else { return false }
        return pipeline.stage >= .startingTTS
    }

    private func interruptResponse() {
        Log.shared.add("Interrupted")
        pipeline?.stop()
        pipeline = nil
        audio.stopResponse()
        media.setDucked(false)
        setPhase(.idle)
    }

    /// "Stop" while talking or while the alarm sounds (Satellite.handleStopWord).
    private func stopWordDetected() {
        Log.shared.add("Stop word")
        if isResponding { interruptResponse() }
        if sounds.isAlarmSounding { setAlarm(false) }
        updateStopWordArmed()
    }

    private func updateStopWordArmed() {
        stopWordArmed = isResponding || sounds.isAlarmSounding
    }

    // MARK: Pipeline

    private func startPipeline(_ mode: PipelineStartMode) {
        pipeline?.stop()
        pipelineCount += 1
        let pipeline = AudioPipeline(
            id: pipelineCount,
            startMode: mode,
            wakeWordName: wakeWord,
            satelliteName: settings.deviceName,
            continueConversation: continueConversation,
            host: self
        )
        self.pipeline = pipeline
        pipeline.start()

        pipelineWatchdog?.invalidate()
        pipelineWatchdog = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self, weak pipeline] timer in
            guard let pipeline, pipeline.isActive else { timer.invalidate(); return }
            pipeline.watchdogTick()
            if self?.pipeline !== pipeline { timer.invalidate() }
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
            processSettings(incoming)
            settingsReceived = true
        case CustomEventType.action:
            if let action = event.action { handleAction(action, event.payload) }
        case CustomEventType.capabilities:
            satelliteConnection?.send(capabilitiesEvent())
        default:
            break
        }
    }

    /// APPConfig.processSettings, for the settings that apply on iOS.
    private func processSettings(_ s: [String: Any]) {
        var wakeChanged = false

        if s["ha_url"] != nil || s["ha_port"] != nil || s["ha_dashboard"] != nil { updateDashboardURL() }

        if let engine = s["wake_word_engine"] as? String, engine != WakeWordEngine.engineName {
            // iOS runs microWakeWord; switch HA's select so its wake word
            // list shows the models this device has.
            sendSetting("wake_word_engine", WakeWordEngine.engineName)
        }
        if let word = s["wake_word"] as? String {
            if let resolved = wake.resolve(word) {
                if resolved != wakeWord { wakeWord = resolved; wakeChanged = true }
                if resolved != word { sendSetting("wake_word", resolved) }
            } else {
                Log.shared.add("Wake word \(word) isn't available on iOS; keeping \(wakeWord)")
                sendSetting("wake_word", wakeWord)
            }
        }
        if let v = Self.number(s["wake_word_threshold"]) {
            let threshold = Float(v / 10)
            if threshold != wakeThreshold { wakeThreshold = threshold; wakeChanged = true }
        }
        if let v = s["wake_word_sound"] as? String { wakeWordSound = v }
        if let v = s["alarm_sound"] as? String { alarmSound = v }
        if let v = Self.number(s["notification_volume"]) {
            audio.voiceVolume = Float(v / 10)
            sounds.effectVolume = Float(v / 10)
            media.announceVolume = Float(v / 10)
        }
        if let v = Self.number(s["music_volume"]) { media.musicVolume = Float(v / 10) }
        if let v = Self.number(s["alarm_volume"]) { sounds.alarmVolume = Float(v / 10) }
        if let v = Self.number(s["ducking_volume"]) { media.duckingVolume = Float(v / 10) }
        if let v = Self.number(s["mic_gain"]) { audio.micGainDb = Float(v) }
        if let v = Self.bool(s["mute"]) {
            if v != muted { muted = v; wakeChanged = true }
        }
        if let v = Self.bool(s["continue_conversation"]) { continueConversation = v }
        if let v = Self.bool(s["screen_on_wake_word"]) { screenOnWakeWord = v }
        if let v = Self.number(s["screen_brightness"]) {
            brightness = CGFloat(max(0, min(100, v)) / 100)
            if screenOn { UIScreen.main.brightness = brightness }
        }
        if let v = Self.bool(s["screen_always_on"]) { screenAlwaysOn = v; resetIdleTimer() }
        if let v = Self.number(s["screen_timeout"]), v > 0 { screenTimeout = v; resetIdleTimer() }
        if let v = Self.bool(s["screen_on"]) { v ? screenWake() : screenSleep() }
        if let v = Self.bool(s["screen_saver"]), v { screenSleep() }
        if s["dark_mode"] != nil { darkMode = Self.bool(s["dark_mode"]) }
        if let v = Self.number(s["zoom_level"]) {
            // HA sends round(zoom * 100) + 60, or 0 for the default.
            pageZoom = v > 0 ? CGFloat(max(0.3, min(3, (v - 60) / 100))) : 1
        }

        if wakeChanged { configureWakeWord() }
    }

    /// Satellite.handleAction
    private func handleAction(_ action: String, _ payload: Any?) {
        let body = payload as? [String: Any] ?? [:]
        Log.shared.add("Action: \(action)")
        switch action {
        case "wake":
            talkNow()
        case "interrupt":
            stopWordDetected()
        case "refresh":
            webCommands.send(.reload)
        case "navigate":
            let target = body["url"] as? String ?? body["path"] as? String ?? payload as? String ?? ""
            if let url = resolve(target) { webCommands.send(.load(url)) }
        case "toast-message":
            if let text = body["message"] as? String ?? payload as? String { showToast(text) }
        case "alarm":
            setAlarm(Self.bool(body["activate"]) ?? false)
        case "screen-wake":
            screenWake()
        case "screen-sleep":
            screenSleep()
        case "play-media":
            guard let text = body["url"] as? String, let url = resolve(text) else { return }
            let volume = Float(Self.number(body["volume"]) ?? 90) / 100
            media.play(url: url, volume: volume, announce: Self.bool(body["announce"]) ?? false)
        case "play":
            media.resume(volume: nil)
        case "pause":
            media.pause()
        case "stop":
            media.stop()
        case "set-volume":
            if let v = Self.number(body["volume"]) { media.musicVolume = Float(v / 100) }
        case "get-logs":
            var event = SatelliteMessages.custom(CustomEventType.logs, [
                "timestamp": SatelliteMessages.isoNow(),
                "request_id": body["request_id"] as? String ?? "",
                "lines": Log.shared.lines.count,
                "level": "V",
            ])
            event.payload = Data(Log.shared.text.utf8)
            satelliteConnection?.send(event)
        default:
            Log.shared.add("Action not supported on iOS: \(action)")
        }
    }

    private func setAlarm(_ on: Bool) {
        if on {
            sounds.startAlarm(alarmSound)
            screenWake()
        } else {
            sounds.stopAlarm()
        }
        updateStopWordArmed()
        sendSetting("alarm", on)
    }

    private func sendSetting(_ name: String, _ value: Any) {
        satelliteConnection?.send(SatelliteMessages.setting(name, value))
    }

    // MARK: Dashboard

    private var haBaseURL: String? {
        if let url = haSettings["ha_url"] as? String, !url.isEmpty {
            return url.hasSuffix("/") ? String(url.dropLast()) : url
        }
        let override = settings.haURLOverride.trimmingCharacters(in: .whitespaces)
        if !override.isEmpty { return override.hasSuffix("/") ? String(override.dropLast()) : override }
        guard let host = haHost else { return nil }
        let port = Self.number(haSettings["ha_port"]).map { Int($0) } ?? 8123
        return "http://\(host):\(port)"
    }

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

    func webPathChanged(_ path: String) {
        guard path != currentPath else { return }
        currentPath = path
        sendStatus()
    }

    // MARK: Screen

    /// iOS apps can't turn the screen off, so "off" is brightness zero with
    /// a black cover; a touch or the wake word turns it back on.
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

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let v as Double: return v
        case let v as Int: return Double(v)
        case let v as String: return Double(v)
        case let v as Bool: return v ? 1 : 0
        default: return nil
        }
    }

    static func bool(_ value: Any?) -> Bool? {
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

// MARK: - AudioPipelineHost

extension Satellite: AudioPipelineHost {
    func pipelineSend(_ event: WyomingEvent) {
        satelliteConnection?.send(event)
    }

    func pipelineStageChanged(_ stage: PipelineStage) {
        switch stage {
        case .started, .listening, .voiceStarted:
            setPhase(.listening)
        case .voiceStopped, .awaitingResponse, .awaitingTTS:
            setPhase(.thinking)
        case .startingTTS, .streamingTTS, .completedTTS:
            setPhase(.speaking)
        case .ended:
            setPhase(.idle)
        default:
            break
        }
        updateStopWordArmed()
    }

    func pipelineMicrophone(enabled: Bool) {
        if enabled {
            // Send what was said since the wake word first, then live audio.
            for chunk in preRoll ?? [] { sendMic(chunk) }
            preRoll = nil
            micStreaming = true
        } else {
            micStreaming = false
            preRoll = nil
        }
    }

    func pipelineRequestTranscript(_ text: String) {
        transcript = text
    }

    func pipelineResponseTranscript(_ text: String) {
        response = text
    }

    func pipelineError(code: String, text: String) {
        Log.shared.add("Pipeline error: \(code) \(text)")
        if code != "duplicate_wake_up_detected" { showError(text.isEmpty ? "Error: \(code)" : text) }
    }

    func pipelineVoiceStart(rate: Int, width: Int, channels: Int) {
        media.setDucked(true)
        audio.beginResponse(rate: rate, channels: channels)
        updateStopWordArmed()
    }

    func pipelineVoiceChunk(_ pcm: Data) {
        audio.appendResponse(pcm)
    }

    func pipelineVoiceDrain(_ done: @escaping () -> Void) {
        audio.drainResponse(done)
    }

    func pipelineVoiceStop() {
        audio.stopResponse()
    }

    func pipelineFinished(_ reason: PipelineEndReason, continueConversation: Bool) {
        Log.shared.add("Pipeline ended: \(reason)\(continueConversation ? ", continuing conversation" : "")")
        pipelineWatchdog?.invalidate()
        pipelineWatchdog = nil
        micStreaming = false
        preRoll = nil
        pipeline = nil
        updateStopWordArmed()

        if reason == .endOfPipeline && continueConversation {
            startPipeline(.continueConversation)
            return
        }
        media.setDucked(false)
        setPhase(.idle)
        resetIdleTimer()
        if reason == .errored && wakeWordSound != "none" { sounds.playError() }
    }
}
