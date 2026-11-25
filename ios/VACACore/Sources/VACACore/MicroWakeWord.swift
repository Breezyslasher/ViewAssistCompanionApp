import Foundation
import MicroFrontend

// Port of the Android app's wakeword/microwakeword package:
// MicroWakeWordDetector, MicroWakeWord and TensorBuffer. The TensorFlow Lite
// interpreter itself lives in the app (it needs the iOS TFLite library);
// everything else is here so it can be tested.

/// Turns 16 kHz mono audio into microWakeWord features: 40 values per 10 ms.
public final class MicroFeatures {
    public static let featureCount = Int(VACA_FRONTEND_FEATURE_COUNT)
    private let frontend: OpaquePointer
    private var pending: [Int16] = []

    public init?() {
        guard let frontend = vaca_frontend_create() else { return nil }
        self.frontend = frontend
    }

    deinit { vaca_frontend_destroy(frontend) }

    /// Returns one feature array per completed 10 ms step.
    public func process(_ samples: [Int16]) -> [[Float]] {
        pending.append(contentsOf: samples)
        var steps: [[Float]] = []
        var offset = 0
        var features = [Float](repeating: 0, count: Self.featureCount)
        let step = Int(VACA_FRONTEND_SAMPLES_PER_STEP)

        while pending.count - offset >= step {
            var read = 0
            let produced = pending.withUnsafeBufferPointer { buffer in
                features.withUnsafeMutableBufferPointer { out in
                    vaca_frontend_process(frontend, buffer.baseAddress! + offset, step, out.baseAddress!, &read)
                }
            }
            if read == 0 { break }
            offset += read
            if produced > 0 { steps.append(features) }
        }
        pending.removeFirst(offset)
        return steps
    }
}

/// Runs one wake word model: features in (already the size the model's
/// input tensor wants), probability out. Implemented with TensorFlow Lite
/// in the app; tests use a fake.
public protocol WakeWordModelRunner: AnyObject {
    /// Number of feature values per inference (e.g. 3 steps x 40 = 120).
    var inputCount: Int { get }
    func probability(for features: [Float]) -> Float?
}

/// A model's settings file, e.g. microwakeword/wakeWords/hey_jarvis.json.
public struct WakeWordManifest: Decodable, Equatable {
    public struct Micro: Decodable, Equatable {
        public let probability_cutoff: Float
        public let sliding_window_size: Int
    }

    public let wake_word: String
    public let model: String
    public let micro: Micro

    public init(wakeWord: String, model: String, cutoff: Float, window: Int) {
        wake_word = wakeWord
        self.model = model
        micro = Micro(probability_cutoff: cutoff, sliding_window_size: window)
    }
}

public struct WakeWordDetection: Equatable {
    public let id: String
    public let wakeWord: String
    public let detected: Bool
    public let score: Float
}

/// One wake word: batches features to the model's input size, and detects
/// when the average of the last few probabilities passes the cutoff
/// (MicroWakeWord.kt).
public final class MicroWakeWord {
    public let id: String
    public let wakeWord: String
    public let probabilityCutoff: Float
    public let slidingWindowSize: Int
    private let runner: WakeWordModelRunner
    private var input: [Float] = []
    private var probabilities: [Float] = []

    public init(id: String, wakeWord: String, runner: WakeWordModelRunner, probabilityCutoff: Float, slidingWindowSize: Int) {
        self.id = id
        self.wakeWord = wakeWord
        self.runner = runner
        self.probabilityCutoff = probabilityCutoff
        self.slidingWindowSize = max(1, slidingWindowSize)
    }

    /// Feed one 10 ms step. Returns nil until the model has enough input.
    public func process(features: [Float]) -> (detected: Bool, probability: Float)? {
        guard !features.isEmpty else { return nil }
        input.append(contentsOf: features)
        guard input.count >= runner.inputCount else { return nil }

        let batch = Array(input.prefix(runner.inputCount))
        input.removeAll(keepingCapacity: true)
        guard let probability = runner.probability(for: batch) else { return nil }

        if probabilities.count == slidingWindowSize { probabilities.removeFirst() }
        probabilities.append(probability)
        let average = probabilities.reduce(0, +) / Float(probabilities.count)
        let detected = probabilities.count == slidingWindowSize && average > probabilityCutoff
        return (detected, probability)
    }

    /// Forget recent probabilities, so one utterance can't trigger twice.
    public func resetWindow() {
        probabilities.removeAll()
    }
}

/// Runs audio through the frontend and every model (MicroWakeWordDetector.kt).
/// Returns, per model, the best result seen in this batch of audio.
public final class MicroWakeWordDetector {
    private let features: MicroFeatures
    public let models: [MicroWakeWord]

    public init?(models: [MicroWakeWord]) {
        guard let features = MicroFeatures() else { return nil }
        self.features = features
        self.models = models
    }

    public func detect(_ samples: [Int16]) -> [WakeWordDetection] {
        var best: [String: WakeWordDetection] = [:]
        for step in features.process(samples) {
            for model in models {
                guard let result = model.process(features: step) else { continue }
                let detection = WakeWordDetection(id: model.id, wakeWord: model.wakeWord,
                                                  detected: result.detected, score: result.probability)
                if let current = best[model.id] {
                    // Keep a detection over a non-detection, then the higher score.
                    if (detection.detected && !current.detected)
                        || (detection.detected == current.detected && detection.score > current.score) {
                        best[model.id] = detection
                    }
                } else {
                    best[model.id] = detection
                }
            }
        }
        return models.compactMap { best[$0.id] }
    }
}

/// Quantisation helpers for int8/uint8 model inputs and outputs (TensorBuffer.kt).
public enum Quantization {
    public static func quantize(_ value: Float, scale: Float, zeroPoint: Int) -> Float {
        value / scale + Float(zeroPoint)
    }

    public static func int8(_ value: Float, scale: Float, zeroPoint: Int) -> Int8 {
        let q = quantize(value, scale: scale, zeroPoint: zeroPoint).rounded()
        return Int8(max(-128, min(127, q)))
    }

    public static func uint8(_ value: Float, scale: Float, zeroPoint: Int) -> UInt8 {
        let q = quantize(value, scale: scale, zeroPoint: zeroPoint).rounded()
        return UInt8(max(0, min(255, q)))
    }

    public static func dequantize(_ value: Int, scale: Float, zeroPoint: Int) -> Float {
        Float(value - zeroPoint) * scale
    }
}
