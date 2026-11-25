import Foundation

// Port of the Android app's satellite/SatelliteAudioPipeline.kt: one voice
// interaction (listen -> intent -> spoken response) over Wyoming messages.
// Audio input/output and timers belong to the host; this is only the state
// machine, so it can be tested.

public enum PipelineStage: Int, Comparable {
    case initial, starting, started, listening, voiceStarted, voiceStopped,
         awaitingResponse, awaitingTTS, startingTTS, streamingTTS, completedTTS, ended

    public static func < (a: PipelineStage, b: PipelineStage) -> Bool { a.rawValue < b.rawValue }
}

public enum PipelineStartMode {
    /// The device heard the wake word (or was woken by hand).
    case wakeWordDetected
    /// Home Assistant started listening (start conversation): `transcribe` arrived first.
    case requestedByServer
    /// Listening again after a response, for a follow-up.
    case continueConversation
    /// Home Assistant sent audio without a pipeline (an announcement).
    case startStreamTTS
}

public enum PipelineEndReason {
    case none, endOfPipeline, forceStopped, timedOut, errored, duplicateWakeup
}

/// What the pipeline needs from the app.
public protocol AudioPipelineHost: AnyObject {
    func pipelineSend(_ event: WyomingEvent)
    func pipelineStageChanged(_ stage: PipelineStage)
    /// Start or stop sending microphone audio (`audio-chunk`s) to Home Assistant.
    func pipelineMicrophone(enabled: Bool)
    func pipelineRequestTranscript(_ text: String)
    func pipelineResponseTranscript(_ text: String)
    func pipelineError(code: String, text: String)
    /// Prepare the voice player for a response.
    func pipelineVoiceStart(rate: Int, width: Int, channels: Int)
    func pipelineVoiceChunk(_ pcm: Data)
    /// No more audio is coming: let what's queued finish (at most about a
    /// second, as on Android), then call `done`.
    func pipelineVoiceDrain(_ done: @escaping () -> Void)
    /// Stop the voice player now.
    func pipelineVoiceStop()
    func pipelineFinished(_ reason: PipelineEndReason, continueConversation: Bool)
}

public final class AudioPipeline {
    /// Words that end a follow-up instead of being sent as a request.
    public static let continuationStopWords = ["never mind"]

    public let id: Int
    public let startMode: PipelineStartMode
    private weak var host: AudioPipelineHost?
    private let wakeWordName: String
    private let satelliteName: String
    private let clock: () -> TimeInterval

    public private(set) var stage: PipelineStage = .initial
    private var stageStart: TimeInterval
    private var startTime: TimeInterval
    private var shouldContinueConversation: Bool
    private var finished = false
    private var micOn = false

    public init(
        id: Int,
        startMode: PipelineStartMode,
        wakeWordName: String,
        satelliteName: String,
        continueConversation: Bool,
        host: AudioPipelineHost,
        clock: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.id = id
        self.startMode = startMode
        self.wakeWordName = wakeWordName
        self.satelliteName = satelliteName
        self.shouldContinueConversation = continueConversation
        self.host = host
        self.clock = clock
        stageStart = clock()
        startTime = stageStart
    }

    public var isActive: Bool { stage != .ended }
    public var isListening: Bool { stage == .listening || stage == .voiceStarted }
    private var isContinuation: Bool { startMode == .continueConversation }

    /// Stages only move forward.
    private func advance(to newStage: PipelineStage) {
        guard newStage > stage else { return }
        stage = newStage
        stageStart = clock()
        updateMicrophone()
        host?.pipelineStageChanged(newStage)
    }

    // The microphone is used from LISTENING until past VOICE_STARTED.
    private func updateMicrophone() {
        if stage == .listening, !micOn {
            micOn = true
            host?.pipelineMicrophone(enabled: true)
        } else if stage > .voiceStarted, micOn {
            micOn = false
            host?.pipelineMicrophone(enabled: false)
        }
    }

    // MARK: Start / stop

    public func start() {
        startTime = clock()
        advance(to: .starting)
        advance(to: .started)
        switch startMode {
        case .wakeWordDetected:
            host?.pipelineSend(detectionEvent())
            host?.pipelineSend(runPipelineEvent())
        case .continueConversation:
            host?.pipelineSend(runPipelineEvent())
        case .startStreamTTS, .requestedByServer:
            shouldContinueConversation = false
        }
    }

    public func stop(_ reason: PipelineEndReason = .forceStopped) {
        if stage != .ended { host?.pipelineSend(SatelliteMessages.pipelineAudioStop()) }
        shouldContinueConversation = false
        finish(reason)
    }

    private func finish(_ reason: PipelineEndReason) {
        guard !finished else { return }
        finished = true
        host?.pipelineVoiceStop()
        advance(to: .ended)
        if micOn {
            micOn = false
            host?.pipelineMicrophone(enabled: false)
        }
        host?.pipelineFinished(reason, continueConversation: reason == .endOfPipeline && shouldContinueConversation)
    }

    // MARK: Watchdog

    /// Call regularly (Android checks every 200 ms). Ends a pipeline stuck in
    /// a stage, or one that hasn't started speaking a response in 20 s.
    public func watchdogTick() {
        guard !finished, stage < .streamingTTS else { return }
        let now = clock()
        if now - startTime > 20 || exceededTimeInStage(now) {
            stop(.timedOut)
        }
    }

    private func exceededTimeInStage(_ now: TimeInterval) -> Bool {
        let seconds = now - stageStart
        switch stage {
        case .started: return seconds > 5
        case .listening: return seconds > 5
        case .voiceStarted: return seconds > 20
        case .awaitingTTS: return seconds > 5
        default: return false
        }
    }

    // MARK: Messages from Home Assistant

    /// Returns false for events this pipeline doesn't handle.
    @discardableResult
    public func handle(_ event: WyomingEvent) -> Bool {
        guard !finished else { return false }
        switch event.type {
        case EventType.transcribe: advance(to: .listening)
        case EventType.voiceStarted: advance(to: .voiceStarted)
        case EventType.voiceStopped: advance(to: .voiceStopped)
        case EventType.transcript: handleTranscript(event)
        case EventType.handled: handleHandled(event)
        case EventType.synthesize: handleSynthesize(event)
        case EventType.audioStart: handleAudioStart(event)
        case EventType.audioChunk: handleAudioChunk(event)
        case EventType.audioStop: handleAudioStop()
        case EventType.pipelineEnded: handlePipelineEnded()
        case EventType.error: handleError(event)
        default: return false
        }
        return true
    }

    private func handleTranscript(_ event: WyomingEvent) {
        let text = event.string("text") ?? ""
        host?.pipelineRequestTranscript(text)
        let normalised = text.lowercased().replacingOccurrences(of: ".", with: "")
        if isContinuation, Self.continuationStopWords.contains(normalised) {
            stop()
            return
        }
        advance(to: .awaitingResponse)
    }

    private func handleHandled(_ event: WyomingEvent) {
        if shouldContinueConversation { return }
        var context = event.data["context"] as? [String: Any]
        if context == nil, let text = event.data["context"] as? String,
           let data = text.data(using: .utf8) {
            context = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        if let output = context?["intent_output"] as? [String: Any] {
            shouldContinueConversation = output["continue_conversation"] as? Bool ?? false
        }
    }

    private func handleSynthesize(_ event: WyomingEvent) {
        let text = event.string("text") ?? ""
        if !text.isEmpty { host?.pipelineResponseTranscript(text) }
        if stage != .streamingTTS { advance(to: .awaitingTTS) }
    }

    private func handleAudioStart(_ event: WyomingEvent) {
        host?.pipelineVoiceStart(
            rate: event.int("rate") ?? 22_050,
            width: event.int("width") ?? 2,
            channels: event.int("channels") ?? 1
        )
        advance(to: .startingTTS)
    }

    private func handleAudioChunk(_ event: WyomingEvent) {
        if stage == .startingTTS { advance(to: .streamingTTS) }
        if stage == .streamingTTS, let payload = event.payload {
            host?.pipelineVoiceChunk(payload)
        }
    }

    private func handleAudioStop() {
        let complete = { [weak self] in
            guard let self, !self.finished else { return }
            self.host?.pipelineSend(SatelliteMessages.played())
            self.advance(to: .completedTTS)
            self.handlePipelineEnded()
        }
        if stage == .streamingTTS {
            host?.pipelineVoiceDrain(complete)
        } else {
            complete()
        }
    }

    private func handlePipelineEnded() {
        if stage == .awaitingTTS || stage == .streamingTTS {
            // Wait for the response to finish playing.
            return
        }
        finish(.endOfPipeline)
    }

    private func handleError(_ event: WyomingEvent) {
        let code = event.string("code") ?? ""
        let text = event.string("text") ?? ""
        host?.pipelineError(code: code, text: text)
        if code == "duplicate_wake_up_detected" {
            finish(.duplicateWakeup)
            return
        }
        shouldContinueConversation = false
        host?.pipelineSend(SatelliteMessages.pipelineAudioStop())
        finish(.errored)
    }

    // MARK: Outgoing messages

    private func detectionEvent() -> WyomingEvent {
        WyomingEvent(type: EventType.detection, data: [
            "name": wakeWordName,
            "timestamp": SatelliteMessages.isoNow(),
            "speaker": "",
        ])
    }

    private func runPipelineEvent() -> WyomingEvent {
        let start = (startMode == .wakeWordDetected || startMode == .continueConversation) ? "asr" : "tts"
        return WyomingEvent(type: EventType.runPipeline, data: [
            "name": satelliteName,
            "start_stage": start,
            "end_stage": "tts",
            "restart_on_end": false,
            "snd_format": ["rate": MicFormat.rate, "width": MicFormat.width, "channels": MicFormat.channels],
        ])
    }
}
