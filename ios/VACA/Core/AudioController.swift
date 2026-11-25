import AVFoundation
import Foundation
import VACACore

/// Microphone capture and voice-response playback, on one AVAudioEngine.
///
/// The microphone runs all the time while Home Assistant is connected: HA
/// listens for the wake word in the stream. With the `audio` background
/// mode this keeps working while the screen is locked.
final class AudioController {
    private let engine = AVAudioEngine()
    private let ttsPlayer = AVAudioPlayerNode()
    private let chimePlayer = AVAudioPlayerNode()
    private var ttsFormat: AVAudioFormat?
    private var resampler: MicResampler?
    private var configured = false

    /// Called on the main queue with 16 kHz mono 16-bit PCM.
    var onMicAudio: ((Data) -> Void)?
    /// Called on the main queue when a response finishes playing.
    var onResponsePlayed: (() -> Void)?

    private var scheduledBuffers = 0
    /// Bumped per response, so completions from a stopped one are ignored.
    private var responseGeneration = 0
    private var responseEnded = false
    private var responseActive = false

    var micGainDb: Float = 0 { didSet { resampler?.gain = Self.gain(micGainDb) } }
    var responseVolume: Float = 1 { didSet { ttsPlayer.volume = responseVolume } }
    var echoCancellation = false

    private(set) var isRunning = false

    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in self?.handleInterruption(note) })
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.handleConfigurationChange() })
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
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
            try session.setPreferredSampleRate(48_000)
            try session.setActive(true)

            if !configured {
                engine.attach(ttsPlayer)
                engine.attach(chimePlayer)
                configured = true
            }
            try? engine.inputNode.setVoiceProcessingEnabled(echoCancellation)

            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                Log.shared.add("No microphone input available")
                return
            }
            let resampler = MicResampler(inputRate: inputFormat.sampleRate)
            resampler.gain = Self.gain(micGainDb)
            self.resampler = resampler

            input.removeTap(onBus: 0)
            // About 85 ms per buffer at 48 kHz.
            input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                guard let channel = buffer.floatChannelData?[0] else { return }
                let pcm = resampler.process(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
                guard !pcm.isEmpty else { return }
                DispatchQueue.main.async { self?.onMicAudio?(pcm) }
            }

            connectTTS(rate: 22_050)
            let chimeFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)
            engine.connect(chimePlayer, to: engine.mainMixerNode, format: chimeFormat)

            engine.prepare()
            try engine.start()
            isRunning = true
            Log.shared.add("Audio started (mic \(Int(inputFormat.sampleRate)) Hz)")
        } catch {
            Log.shared.add("Audio start failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        ttsPlayer.stop()
        chimePlayer.stop()
        engine.stop()
        isRunning = false
        resampler = nil
    }

    func restart() {
        stop()
        start()
    }

    private static func gain(_ db: Float) -> Float { powf(10, db / 20) }

    // MARK: Response playback

    private func connectTTS(rate: Double) {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) else { return }
        if ttsFormat?.sampleRate == rate { return }
        engine.disconnectNodeOutput(ttsPlayer)
        engine.connect(ttsPlayer, to: engine.mainMixerNode, format: format)
        ttsFormat = format
    }

    /// `audio-start` from Home Assistant.
    func beginResponse(rate: Int, channels: Int) {
        if !isRunning { start() }
        ttsPlayer.stop()
        responseGeneration += 1
        scheduledBuffers = 0
        responseEnded = false
        responseActive = true
        if channels != 1 { Log.shared.add("Response has \(channels) channels; playing the first") }
        connectTTS(rate: Double(rate))
        ttsPlayer.volume = responseVolume
        ttsPlayer.play()
    }

    /// `audio-chunk` from Home Assistant: 16-bit PCM.
    func appendResponse(_ pcm: Data, channels: Int) {
        guard responseActive, let format = ttsFormat else { return }
        var samples = PCM.int16ToFloat(pcm)
        if channels > 1 {
            samples = stride(from: 0, to: samples.count, by: channels).map { samples[$0] }
        }
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }

        scheduledBuffers += 1
        let generation = responseGeneration
        ttsPlayer.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, generation == self.responseGeneration else { return }
                self.scheduledBuffers = max(0, self.scheduledBuffers - 1)
                self.finishIfDone()
            }
        }
        if !ttsPlayer.isPlaying { ttsPlayer.play() }
    }

    /// `audio-stop` from Home Assistant: no more audio is coming.
    func endResponse() {
        guard responseActive else { return }
        responseEnded = true
        finishIfDone()
    }

    /// Stop speaking now (interrupt). Reports the response as played.
    func cancelResponse() {
        guard responseActive else { return }
        responseGeneration += 1
        ttsPlayer.stop()
        scheduledBuffers = 0
        responseEnded = true
        finishIfDone()
    }

    private func finishIfDone() {
        guard responseActive, responseEnded, scheduledBuffers == 0 else { return }
        responseActive = false
        onResponsePlayed?()
    }

    // MARK: Chime

    /// A short two-note chime when the wake word is heard.
    func playWakeChime() {
        guard isRunning, let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1) else { return }
        let rate = 44_100.0
        let notes: [(Double, Double)] = [(880, 0.07), (1320, 0.09)]
        let total = notes.reduce(0) { $0 + Int($1.1 * rate) }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)),
              let out = buffer.floatChannelData?[0] else { return }
        var i = 0
        for (frequency, duration) in notes {
            let n = Int(duration * rate)
            for k in 0..<n {
                let fade = min(1, Double(min(k, n - k)) / (0.01 * rate))
                out[i] = Float(sin(2 * .pi * frequency * Double(k) / rate) * 0.3 * fade)
                i += 1
            }
        }
        buffer.frameLength = AVAudioFrameCount(total)
        chimePlayer.volume = responseVolume
        chimePlayer.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        chimePlayer.play()
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

    private func handleConfigurationChange() {
        // Route changed (headphones, Bluetooth); the input format may differ.
        Log.shared.add("Audio route changed; restarting")
        ttsFormat = nil
        restart()
    }
}
