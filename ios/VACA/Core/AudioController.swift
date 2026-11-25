import AVFoundation
import Foundation
import VACACore

/// Microphone capture and voice-response playback on one AVAudioEngine
/// (the Android app's MicrophoneInput + voice player).
///
/// The microphone runs all the time for on-device wake word detection. With
/// the `audio` background mode this keeps working while the screen is locked.
final class AudioController {
    private let engine = AVAudioEngine()
    private let voicePlayer = AVAudioPlayerNode()
    private var voiceFormat: AVAudioFormat?
    private var resampler: MicResampler?
    private var attached = false

    /// Microphone audio, 16 kHz mono 16-bit PCM, about every 64 ms. Called on
    /// `micQueue`, not the main queue, so wake word detection stays off it.
    var onMicAudio: ((Data) -> Void)?
    let micQueue = DispatchQueue(label: "vaca.mic", qos: .userInteractive)

    private var scheduledBuffers = 0
    private var responseGeneration = 0
    private var drainCompletion: (() -> Void)?
    private var drainDeadline: DispatchWorkItem?
    private(set) var isResponding = false

    var micGainDb: Float = 0 {
        didSet { let g = Self.gain(micGainDb); micQueue.async { self.resampler?.gain = g } }
    }
    var voiceVolume: Float = 1 { didSet { voicePlayer.volume = voiceVolume } }
    var echoCancellation = true

    private(set) var isRunning = false
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in self?.handleInterruption(note) })
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Log.shared.add("Audio route changed; restarting")
            self?.voiceFormat = nil
            self?.restart()
        })
    }

    static func requestPermission(_ done: @escaping (Bool) -> Void) {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async { done(granted) }
        }
    }

    // MARK: Start / stop

    func start() {
        guard !isRunning else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            // Other audio (including our own media player) keeps playing.
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, .mixWithOthers])
            try session.setPreferredSampleRate(48_000)
            try session.setActive(true)

            if !attached {
                engine.attach(voicePlayer)
                attached = true
            }
            // Echo cancellation keeps the device's own voice and sounds out of
            // the wake word detector, like the Android app's AEC.
            try? engine.inputNode.setVoiceProcessingEnabled(echoCancellation)

            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                Log.shared.add("No microphone input available")
                return
            }
            let resampler = MicResampler(inputRate: inputFormat.sampleRate)
            resampler.gain = Self.gain(micGainDb)
            micQueue.sync { self.resampler = resampler }

            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 3072, format: inputFormat) { [weak self] buffer, _ in
                guard let self, let channel = buffer.floatChannelData?[0] else { return }
                let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
                self.micQueue.async {
                    guard let resampler = self.resampler else { return }
                    let pcm = samples.withUnsafeBufferPointer { resampler.process($0) }
                    if !pcm.isEmpty { self.onMicAudio?(pcm) }
                }
            }

            connectVoice(rate: 22_050)
            engine.prepare()
            try engine.start()
            isRunning = true
            Log.shared.add("Audio started (mic \(Int(inputFormat.sampleRate)) Hz, echo cancellation \(echoCancellation ? "on" : "off"))")
        } catch {
            Log.shared.add("Audio start failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        stopResponse()
        engine.stop()
        isRunning = false
    }

    func restart() {
        stop()
        isRunning = false
        start()
    }

    private static func gain(_ db: Float) -> Float { powf(10, db / 20) }

    // MARK: Voice response

    private func connectVoice(rate: Double) {
        if voiceFormat?.sampleRate == rate { return }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) else { return }
        engine.disconnectNodeOutput(voicePlayer)
        engine.connect(voicePlayer, to: engine.mainMixerNode, format: format)
        voiceFormat = format
    }

    /// `audio-start`: get ready for a response.
    func beginResponse(rate: Int, channels: Int) {
        if !isRunning { start() }
        stopResponse()
        isResponding = true
        connectVoice(rate: Double(rate))
        voicePlayer.volume = voiceVolume
        voicePlayer.play()
    }

    /// `audio-chunk`: 16-bit PCM.
    func appendResponse(_ pcm: Data) {
        guard isResponding, let format = voiceFormat else { return }
        let samples = PCM.int16ToFloat(pcm)
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }

        scheduledBuffers += 1
        let generation = responseGeneration
        voicePlayer.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, generation == self.responseGeneration else { return }
                self.scheduledBuffers = max(0, self.scheduledBuffers - 1)
                self.finishDrainIfDone()
            }
        }
        if !voicePlayer.isPlaying { voicePlayer.play() }
    }

    /// `audio-stop`: call `done` once everything queued has played.
    func drainResponse(_ done: @escaping () -> Void) {
        guard isResponding else { done(); return }
        drainCompletion = done
        // Safety net in case a completion callback never arrives.
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.drainCompletion != nil else { return }
            Log.shared.add("Response playback did not report finishing; continuing")
            self.stopResponse()
        }
        drainDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: deadline)
        finishDrainIfDone()
    }

    /// Stop speaking now. Runs any pending drain completion.
    func stopResponse() {
        responseGeneration += 1
        voicePlayer.stop()
        scheduledBuffers = 0
        isResponding = false
        drainDeadline?.cancel()
        drainDeadline = nil
        if let done = drainCompletion {
            drainCompletion = nil
            done()
        }
    }

    private func finishDrainIfDone() {
        guard drainCompletion != nil, scheduledBuffers == 0 else { return }
        stopResponse()
    }

    // MARK: Interruptions

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            Log.shared.add("Audio interrupted")
            isRunning = false
        case .ended:
            Log.shared.add("Audio interruption ended; restarting")
            restart()
        @unknown default:
            break
        }
    }
}
