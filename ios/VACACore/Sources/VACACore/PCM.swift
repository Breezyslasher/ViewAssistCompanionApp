import Foundation

/// Converts microphone audio (Float32 at the hardware rate, usually 48 kHz)
/// to the 16 kHz signed 16-bit mono PCM Home Assistant expects.
///
/// Each output sample is the average of the input samples it covers, which
/// acts as a simple low-pass filter so speech doesn't alias when the rate
/// drops. It keeps its position between calls, so feeding it buffers of any
/// size gives the same output as one long buffer.
public final class MicResampler {
    public let inputRate: Double
    public let outputRate: Double
    private let step: Double
    /// Input samples not yet turned into output, carried into the next call.
    private var carry: [Float] = []
    /// Fractional start of the next output sample within `carry[0]`.
    private var position: Double = 0
    /// Linear gain applied before converting to Int16.
    public var gain: Float = 1

    public init(inputRate: Double, outputRate: Double = Double(MicFormat.rate)) {
        self.inputRate = inputRate
        self.outputRate = outputRate
        step = inputRate / outputRate
    }

    public func process(_ samples: UnsafeBufferPointer<Float>) -> Data {
        // Input left over from the last call comes first.
        let input = carry + Array(samples)
        var out = [Int16]()
        out.reserveCapacity(Int(Double(input.count) / step) + 1)

        var start = position
        while start + step <= Double(input.count) {
            let lo = Int(start)
            let hi = min(input.count, max(lo + 1, Int(start + step)))
            var sum: Float = 0
            for i in lo..<hi { sum += input[i] }
            let value = (sum / Float(hi - lo)) * gain
            let clamped = max(-1, min(1, value))
            out.append(Int16(clamped * Float(Int16.max)))
            start += step
        }

        let keepFrom = Int(start)
        carry = keepFrom < input.count ? Array(input[keepFrom...]) : []
        position = start - Double(keepFrom)

        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public func reset() {
        position = 0
        carry = []
    }
}

public enum PCM {
    /// Signed 16-bit little-endian PCM to Float32 in -1...1.
    public static func int16ToFloat(_ data: Data) -> [Float] {
        let count = data.count / 2
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                let sample = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
                out[i] = Float(sample) / 32768
            }
        }
        return out
    }

    /// Duration in milliseconds of 16-bit PCM.
    public static func milliseconds(bytes: Int, rate: Int, width: Int = 2, channels: Int = 1) -> Int {
        guard rate > 0, width > 0, channels > 0 else { return 0 }
        return (bytes / (width * channels)) * 1000 / rate
    }
}
