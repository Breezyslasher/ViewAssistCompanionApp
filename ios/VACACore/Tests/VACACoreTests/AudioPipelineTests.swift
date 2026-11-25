import XCTest
@testable import VACACore

/// Records what the pipeline asks of the app.
private final class FakeHost: AudioPipelineHost {
    var sent: [WyomingEvent] = []
    var stages: [PipelineStage] = []
    var micStates: [Bool] = []
    var voiceChunks = 0
    var voiceStopped = 0
    var pendingDrain: (() -> Void)?
    var finished: (PipelineEndReason, Bool)?
    var errors: [String] = []

    var sentTypes: [String] { sent.map(\.type) }

    func pipelineSend(_ event: WyomingEvent) { sent.append(event) }
    func pipelineStageChanged(_ stage: PipelineStage) { stages.append(stage) }
    func pipelineMicrophone(enabled: Bool) { micStates.append(enabled) }
    func pipelineRequestTranscript(_ text: String) {}
    func pipelineResponseTranscript(_ text: String) {}
    func pipelineError(code: String, text: String) { errors.append(code) }
    func pipelineVoiceStart(rate: Int, width: Int, channels: Int) {}
    func pipelineVoiceChunk(_ pcm: Data) { voiceChunks += 1 }
    func pipelineVoiceDrain(_ done: @escaping () -> Void) { pendingDrain = done }
    func pipelineVoiceStop() { voiceStopped += 1 }
    func pipelineFinished(_ reason: PipelineEndReason, continueConversation: Bool) {
        finished = (reason, continueConversation)
    }
}

final class AudioPipelineTests: XCTestCase {
    private var now: TimeInterval = 1000
    private var host: FakeHost!

    override func setUp() {
        now = 1000
        host = FakeHost()
    }

    private func pipeline(_ mode: PipelineStartMode = .wakeWordDetected, continueConversation: Bool = false) -> AudioPipeline {
        let p = AudioPipeline(id: 1, startMode: mode, wakeWordName: "hey_jarvis", satelliteName: "VACA test",
                              continueConversation: continueConversation, host: host, clock: { [unowned self] in self.now })
        p.start()
        return p
    }

    private func event(_ type: String, _ data: [String: Any] = [:], payload: Data? = nil) -> WyomingEvent {
        WyomingEvent(type: type, data: data, payload: payload)
    }

    /// The normal flow: wake word, request, spoken response.
    private func runToResponse(_ p: AudioPipeline) {
        p.handle(event("transcribe"))
        p.handle(event("voice-started"))
        p.handle(event("voice-stopped"))
        p.handle(event("transcript", ["text": "turn on the lights"]))
        p.handle(event("synthesize", ["text": "Done"]))
        p.handle(event("audio-start", ["rate": 22050, "width": 2, "channels": 1]))
        p.handle(event("audio-chunk", payload: Data([0, 0])))
        p.handle(event("audio-chunk", payload: Data([0, 0])))
    }

    func testWakeWordSendsDetectionThenRunPipelineFromASR() {
        _ = pipeline()
        XCTAssertEqual(host.sentTypes, ["detection", "run-pipeline"])
        XCTAssertEqual(host.sent[0].string("name"), "hey_jarvis")
        XCTAssertEqual(host.sent[1].string("start_stage"), "asr")
        XCTAssertEqual(host.sent[1].string("end_stage"), "tts")
        XCTAssertEqual(host.sent[1].data["restart_on_end"] as? Bool, false)
    }

    func testAnnouncementSendsNothingAtStart() {
        _ = pipeline(.startStreamTTS)
        XCTAssertTrue(host.sent.isEmpty)
    }

    func testMicrophoneOnlyWhileListening() {
        let p = pipeline()
        XCTAssertEqual(host.micStates, [])
        p.handle(event("transcribe"))
        XCTAssertEqual(host.micStates, [true])
        p.handle(event("voice-started"))
        XCTAssertEqual(host.micStates, [true])
        p.handle(event("voice-stopped"))
        XCTAssertEqual(host.micStates, [true, false])
    }

    func testFullResponseSendsPlayedAfterDrainAndEnds() {
        let p = pipeline()
        runToResponse(p)
        XCTAssertEqual(host.voiceChunks, 2)
        XCTAssertEqual(p.stage, .streamingTTS)

        // HA reports the run ended while audio is still playing: keep going.
        p.handle(event("pipeline-ended"))
        XCTAssertNil(host.finished)

        p.handle(event("audio-stop"))
        XCTAssertFalse(host.sentTypes.contains("played"), "played waits for playback to drain")
        host.pendingDrain?()
        XCTAssertEqual(host.sentTypes.last, "played")
        XCTAssertEqual(host.finished?.0, .endOfPipeline)
        XCTAssertEqual(host.finished?.1, false)
        XCTAssertEqual(p.stage, .ended)
    }

    func testStagesNeverGoBackwards() {
        let p = pipeline()
        p.handle(event("transcribe"))
        p.handle(event("voice-stopped"))
        p.handle(event("voice-started"))
        XCTAssertEqual(p.stage, .voiceStopped)
    }

    func testListeningTimesOutAfterFiveSeconds() {
        let p = pipeline()
        p.handle(event("transcribe"))
        now += 4.9
        p.watchdogTick()
        XCTAssertNil(host.finished)
        now += 0.2
        p.watchdogTick()
        XCTAssertEqual(host.finished?.0, .timedOut)
        XCTAssertEqual(host.sentTypes.last, "audio-stop")
        XCTAssertEqual(host.micStates.last, false)
    }

    func testWatchdogStopsOnceResponseIsStreaming() {
        let p = pipeline()
        runToResponse(p)
        now += 60
        p.watchdogTick()
        XCTAssertNil(host.finished)
    }

    func testErrorEndsPipeline() {
        let p = pipeline()
        p.handle(event("transcribe"))
        p.handle(event("error", ["code": "stt-no-text-recognized", "text": "No text recognized"]))
        XCTAssertEqual(host.finished?.0, .errored)
        XCTAssertEqual(host.errors, ["stt-no-text-recognized"])
        XCTAssertEqual(host.sentTypes.last, "audio-stop")
    }

    func testHandledIntentCanContinueConversation() {
        let p = pipeline()
        runToResponse(p)
        p.handle(event("handled", ["context": ["intent_output": ["continue_conversation": true]]]))
        p.handle(event("audio-stop"))
        host.pendingDrain?()
        XCTAssertEqual(host.finished?.0, .endOfPipeline)
        XCTAssertEqual(host.finished?.1, true)
    }

    func testFollowUpEndsOnNeverMind() {
        let p = pipeline(.continueConversation)
        XCTAssertEqual(host.sentTypes, ["run-pipeline"])
        p.handle(event("transcribe"))
        p.handle(event("transcript", ["text": "Never mind."]))
        XCTAssertEqual(host.finished?.0, .forceStopped)
        XCTAssertEqual(host.finished?.1, false)
    }

    func testFinishesOnlyOnce() {
        let p = pipeline()
        p.stop()
        p.stop(.timedOut)
        p.handle(event("pipeline-ended"))
        XCTAssertEqual(host.finished?.0, .forceStopped)
        XCTAssertEqual(host.voiceStopped, 1)
    }
}

/// Fixed-output model, to test the detection logic without TensorFlow Lite.
private final class FakeRunner: WakeWordModelRunner {
    let inputCount: Int
    var output: Float
    var calls = 0
    init(inputCount: Int, output: Float) {
        self.inputCount = inputCount
        self.output = output
    }
    func probability(for features: [Float]) -> Float? {
        XCTAssertEqual(features.count, inputCount)
        calls += 1
        return output
    }
}

final class MicroWakeWordTests: XCTestCase {
    func testFrontendGives40FeaturesPer10ms() throws {
        let frontend = try XCTUnwrap(MicroFeatures())
        let tone = (0..<16_000).map { Int16(8000 * sin(2 * .pi * 440 * Double($0) / 16_000)) }
        // Fed in uneven pieces; the frontend keeps leftovers.
        var steps: [[Float]] = []
        var i = 0
        for size in [37, 1000, 160, 4800, 9999] {
            let end = min(tone.count, i + size)
            steps += frontend.process(Array(tone[i..<end]))
            i = end
        }
        steps += frontend.process(Array(tone[i...]))
        // First output needs a full 30 ms window, then one per 10 ms.
        XCTAssertEqual(steps.count, 98)
        XCTAssertTrue(steps.allSatisfy { $0.count == 40 })
        // Early on (before noise reduction adapts) 440 Hz lands in channel 4.
        let early = steps[4]
        XCTAssertEqual(early.firstIndex(of: early.max()!), 4)
    }

    func testDetectsWhenWindowAveragePassesCutoff() {
        let runner = FakeRunner(inputCount: 120, output: 0.9)
        let word = MicroWakeWord(id: "hey_jarvis", wakeWord: "Hey Jarvis", runner: runner,
                                 probabilityCutoff: 0.8, slidingWindowSize: 3)
        let step = [Float](repeating: 0, count: 40)
        var results: [Bool] = []
        for _ in 0..<9 {
            if let result = word.process(features: step) { results.append(result.detected) }
        }
        // Runs every 3 steps (120 values); detects once the window of 3 is full.
        XCTAssertEqual(runner.calls, 3)
        XCTAssertEqual(results, [false, false, true])
    }

    func testNoDetectionBelowCutoff() {
        let word = MicroWakeWord(id: "a", wakeWord: "A", runner: FakeRunner(inputCount: 40, output: 0.5),
                                 probabilityCutoff: 0.6, slidingWindowSize: 2)
        let step = [Float](repeating: 0, count: 40)
        XCTAssertFalse((0..<5).contains { _ in word.process(features: step)?.detected == true })
    }

    func testQuantizationClamps() {
        XCTAssertEqual(Quantization.int8(1000, scale: 0.1, zeroPoint: -128), 127)
        XCTAssertEqual(Quantization.int8(0, scale: 0.1, zeroPoint: -128), -128)
        XCTAssertEqual(Quantization.uint8(25.5, scale: 0.1, zeroPoint: 0), 255)
        XCTAssertEqual(Quantization.dequantize(255, scale: 1.0 / 256, zeroPoint: 0), 255.0 / 256, accuracy: 1e-6)
    }

    func testManifestDecodes() throws {
        let json = """
        {"type":"micro","wake_word":"Hey Jarvis","model":"hey_jarvis.tflite",
         "micro":{"probability_cutoff":0.97,"feature_step_size":10,"sliding_window_size":5}}
        """
        let manifest = try JSONDecoder().decode(WakeWordManifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest, WakeWordManifest(wakeWord: "Hey Jarvis", model: "hey_jarvis.tflite", cutoff: 0.97, window: 5))
    }
}
