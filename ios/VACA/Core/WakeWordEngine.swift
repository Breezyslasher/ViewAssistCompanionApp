import Foundation
import TensorFlowLite
import VACACore

/// Runs a microWakeWord model with TensorFlow Lite (MicroWakeWord.kt).
final class TFLiteRunner: WakeWordModelRunner {
    private let interpreter: Interpreter
    let inputCount: Int
    private let inputType: Tensor.DataType
    private let inputScale: Float
    private let inputZeroPoint: Int

    init(modelPath: String) throws {
        var options = Interpreter.Options()
        options.threadCount = 1
        interpreter = try Interpreter(modelPath: modelPath, options: options)
        try interpreter.allocateTensors()
        let input = try interpreter.input(at: 0)
        inputCount = input.shape.dimensions.reduce(1, *)
        inputType = input.dataType
        inputScale = input.quantizationParameters?.scale ?? 1
        inputZeroPoint = input.quantizationParameters?.zeroPoint ?? 0
    }

    func probability(for features: [Float]) -> Float? {
        do {
            let data: Data
            switch inputType {
            case .int8:
                let values = features.map { Quantization.int8($0, scale: inputScale, zeroPoint: inputZeroPoint) }
                data = values.withUnsafeBufferPointer { Data(buffer: $0) }
            case .uInt8:
                let values = features.map { Quantization.uint8($0, scale: inputScale, zeroPoint: inputZeroPoint) }
                data = values.withUnsafeBufferPointer { Data(buffer: $0) }
            default:
                data = features.withUnsafeBufferPointer { Data(buffer: $0) }
            }
            try interpreter.copy(data, toInputAt: 0)
            try interpreter.invoke()

            let output = try interpreter.output(at: 0)
            let scale = output.quantizationParameters?.scale ?? 1
            let zeroPoint = output.quantizationParameters?.zeroPoint ?? 0
            guard let first = output.data.first else { return nil }
            switch output.dataType {
            case .uInt8:
                return Quantization.dequantize(Int(first), scale: scale, zeroPoint: zeroPoint)
            case .int8:
                return Quantization.dequantize(Int(Int8(bitPattern: first)), scale: scale, zeroPoint: zeroPoint)
            default:
                return output.data.withUnsafeBytes { $0.load(as: Float.self) }
            }
        } catch {
            Log.shared.add("Wake word model error: \(error)")
            return nil
        }
    }
}

/// A wake word model bundled with the app (from the Android app's assets).
struct BundledWakeWord {
    let id: String
    let manifest: WakeWordManifest
    let modelPath: String
}

/// The microWakeWord engine (MicroWakeWordEngine.kt): listens to the
/// microphone for the chosen wake word, and for "stop" while the device is
/// talking or an alarm is sounding.
///
/// Everything except the callbacks runs on the microphone queue.
final class WakeWordEngine {
    static let engineName = "microwakeword"

    /// Wake words shipped with the app (microwakeword/wakeWords).
    let available: [BundledWakeWord]
    private let stopWords: [BundledWakeWord]

    private var detector: MicroWakeWordDetector?
    private var activeWakeWord = ""
    private var threshold: Float = -1
    /// Detections are ignored until this time, so one utterance fires once
    /// (like the Android DetectionRearmGate).
    private var rearmAt = Date.distantPast

    /// Called on the main queue.
    var onWakeWord: ((WakeWordDetection) -> Void)?
    var onStopWord: (() -> Void)?
    /// Whether "stop" should be acted on right now. Read on the mic queue.
    var stopWordActive: () -> Bool = { false }
    var muted = false

    init() {
        available = Self.load(folder: "microwakeword/wakeWords")
        stopWords = Self.load(folder: "microwakeword/stopWords")
        Log.shared.add("Wake words available: \(available.map(\.id).joined(separator: ", "))")
    }

    private static func load(folder: String) -> [BundledWakeWord] {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent(folder),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let manifest = try? JSONDecoder().decode(WakeWordManifest.self, from: data) else { return nil }
            let model = dir.appendingPathComponent(manifest.model).path
            guard FileManager.default.fileExists(atPath: model) else { return nil }
            return BundledWakeWord(id: url.deletingPathExtension().lastPathComponent, manifest: manifest, modelPath: model)
        }.sorted { $0.id < $1.id }
    }

    /// The id to use for a wake word Home Assistant names, mapping
    /// openWakeWord names to the matching microWakeWord model.
    func resolve(_ id: String) -> String? {
        let aliases = ["ok_nabu": "okay_nabu", "hey_home_assistant": "hey_home_assistant"]
        let wanted = aliases[id] ?? id
        return available.first { $0.id == wanted }?.id
    }

    /// Switch wake word and threshold (0...1; below 0 uses the model's own).
    func configure(wakeWord: String, threshold: Float) {
        guard wakeWord != activeWakeWord || threshold != self.threshold || detector == nil else { return }
        activeWakeWord = wakeWord
        self.threshold = threshold
        do {
            var models: [MicroWakeWord] = []
            if let word = available.first(where: { $0.id == wakeWord }) {
                models.append(try model(word, threshold: threshold))
            }
            for stop in stopWords {
                models.append(try model(stop, threshold: -1))
            }
            detector = MicroWakeWordDetector(models: models)
            Log.shared.add("Wake word engine ready: \(wakeWord) (threshold \(threshold >= 0 ? String(threshold) : "model default"))")
        } catch {
            detector = nil
            Log.shared.add("Could not load wake word \(wakeWord): \(error)")
        }
    }

    private func model(_ word: BundledWakeWord, threshold: Float) throws -> MicroWakeWord {
        MicroWakeWord(
            id: word.id,
            wakeWord: word.manifest.wake_word,
            runner: try TFLiteRunner(modelPath: word.modelPath),
            probabilityCutoff: threshold >= 0 ? threshold : word.manifest.micro.probability_cutoff,
            slidingWindowSize: word.manifest.micro.sliding_window_size
        )
    }

    /// Feed microphone audio. Always runs the models (they keep state
    /// between calls), as on Android.
    func process(_ pcm: Data) {
        guard let detector, !muted else { return }
        let samples: [Int16] = pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        let detections = detector.detect(samples)
        guard Date() >= rearmAt else { return }

        for detection in detections where detection.detected {
            let isStop = stopWords.contains { $0.id == detection.id }
            if isStop {
                guard stopWordActive() else { continue }
                rearm(detector)
                DispatchQueue.main.async { self.onStopWord?() }
            } else if detection.id == activeWakeWord {
                rearm(detector)
                DispatchQueue.main.async { self.onWakeWord?(detection) }
            }
            return
        }
    }

    private func rearm(_ detector: MicroWakeWordDetector) {
        rearmAt = Date().addingTimeInterval(1.0)
        for model in detector.models { model.resetWindow() }
    }
}
