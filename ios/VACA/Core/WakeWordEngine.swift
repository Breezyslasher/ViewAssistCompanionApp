import Foundation
import TensorFlowLiteC
import VACACore

/// Runs a microWakeWord model with TensorFlow Lite (MicroWakeWord.kt).
///
/// Uses the TFLite C API: the Swift wrapper has no int8 tensor type, and
/// microWakeWord models take int8 input.
final class TFLiteRunner: WakeWordModelRunner {
    enum LoadError: Error { case model, interpreter, tensors, input, output }

    private let model: OpaquePointer
    private let options: OpaquePointer
    private let interpreter: OpaquePointer
    let inputCount: Int
    private let inputType: TfLiteType
    private let inputQuant: TfLiteQuantizationParams

    init(modelPath: String) throws {
        guard let model = TfLiteModelCreateFromFile(modelPath) else { throw LoadError.model }
        guard let options = TfLiteInterpreterOptionsCreate() else {
            TfLiteModelDelete(model)
            throw LoadError.interpreter
        }
        TfLiteInterpreterOptionsSetNumThreads(options, 1)
        guard let interpreter = TfLiteInterpreterCreate(model, options) else {
            TfLiteInterpreterOptionsDelete(options)
            TfLiteModelDelete(model)
            throw LoadError.interpreter
        }
        self.model = model
        self.options = options
        self.interpreter = interpreter

        guard TfLiteInterpreterAllocateTensors(interpreter) == kTfLiteOk else { throw LoadError.tensors }
        guard let input = TfLiteInterpreterGetInputTensor(interpreter, 0) else { throw LoadError.input }
        var count = 1
        for i in 0..<TfLiteTensorNumDims(input) { count *= Int(TfLiteTensorDim(input, i)) }
        inputCount = count
        inputType = TfLiteTensorType(input)
        inputQuant = TfLiteTensorQuantizationParams(input)
    }

    deinit {
        TfLiteInterpreterDelete(interpreter)
        TfLiteInterpreterOptionsDelete(options)
        TfLiteModelDelete(model)
    }

    func probability(for features: [Float]) -> Float? {
        let scale = inputQuant.scale == 0 ? 1 : inputQuant.scale
        let zeroPoint = Int(inputQuant.zero_point)

        guard let input = TfLiteInterpreterGetInputTensor(interpreter, 0) else { return nil }
        let status: TfLiteStatus
        if inputType == kTfLiteInt8 {
            let values = features.map { Quantization.int8($0, scale: scale, zeroPoint: zeroPoint) }
            status = values.withUnsafeBytes { TfLiteTensorCopyFromBuffer(input, $0.baseAddress, $0.count) }
        } else if inputType == kTfLiteUInt8 {
            let values = features.map { Quantization.uint8($0, scale: scale, zeroPoint: zeroPoint) }
            status = values.withUnsafeBytes { TfLiteTensorCopyFromBuffer(input, $0.baseAddress, $0.count) }
        } else {
            status = features.withUnsafeBytes { TfLiteTensorCopyFromBuffer(input, $0.baseAddress, $0.count) }
        }
        guard status == kTfLiteOk, TfLiteInterpreterInvoke(interpreter) == kTfLiteOk,
              let output = TfLiteInterpreterGetOutputTensor(interpreter, 0) else {
            return nil
        }

        let outQuant = TfLiteTensorQuantizationParams(output)
        let outScale = outQuant.scale == 0 ? 1 : outQuant.scale
        let outZero = Int(outQuant.zero_point)
        let type = TfLiteTensorType(output)
        var bytes = [UInt8](repeating: 0, count: max(4, TfLiteTensorByteSize(output)))
        let copied = bytes.withUnsafeMutableBytes {
            TfLiteTensorCopyToBuffer(output, $0.baseAddress, TfLiteTensorByteSize(output))
        }
        guard copied == kTfLiteOk else { return nil }

        if type == kTfLiteUInt8 {
            return Quantization.dequantize(Int(bytes[0]), scale: outScale, zeroPoint: outZero)
        } else if type == kTfLiteInt8 {
            return Quantization.dequantize(Int(Int8(bitPattern: bytes[0])), scale: outScale, zeroPoint: outZero)
        } else {
            return bytes.withUnsafeBytes { $0.load(as: Float.self) }
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
