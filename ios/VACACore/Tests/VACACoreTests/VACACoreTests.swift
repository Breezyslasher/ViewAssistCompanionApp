import XCTest
@testable import VACACore

final class WyomingParserTests: XCTestCase {
    /// Written by the Python `wyoming` 1.11.0 library (what Home Assistant
    /// uses): describe, an audio chunk with data and payload, a VACA settings
    /// event, and run-satellite.
    private let pythonStream = Data(base64Encoded:
        "eyJ0eXBlIjogImRlc2NyaWJlIiwgInZlcnNpb24iOiAiMS4xMS4wIn0KeyJ0eXBlIjogImF1ZGlvLWNodW5rIiwgInZlcnNpb24iOiAiMS4xMS4wIiwgImRhdGFfbGVuZ3RoIjogNTgsICJwYXlsb2FkX2xlbmd0aCI6IDEwfQp7InJhdGUiOiAyMjA1MCwgIndpZHRoIjogMiwgImNoYW5uZWxzIjogMSwgInRpbWVzdGFtcCI6IDV9AAECAwQFBgcICXsidHlwZSI6ICJjdXN0b20tZXZlbnQiLCAidmVyc2lvbiI6ICIxLjExLjAiLCAiZGF0YV9sZW5ndGgiOiA5OX0KeyJldmVudF90eXBlIjogInNldHRpbmdzIiwgInNldHRpbmdzIjogeyJzY3JlZW5fYnJpZ2h0bmVzcyI6IDQwLCAiaGFfdXJsIjogImh0dHA6Ly9oYS5sb2NhbDo4MTIzIn19eyJ0eXBlIjogInJ1bi1zYXRlbGxpdGUiLCAidmVyc2lvbiI6ICIxLjExLjAifQo="
    )!

    private func checkPythonEvents(_ events: [WyomingEvent]) {
        XCTAssertEqual(events.map(\.type), ["describe", "audio-chunk", "custom-event", "run-satellite"])

        let chunk = events[1]
        XCTAssertEqual(chunk.int("rate"), 22050)
        XCTAssertEqual(chunk.int("timestamp"), 5)
        XCTAssertEqual(chunk.payload, Data(0..<10))

        let custom = IncomingCustomEvent(events[2])
        XCTAssertEqual(custom?.eventType, "settings")
        XCTAssertEqual(custom?.settings["screen_brightness"] as? Int, 40)
        XCTAssertEqual(custom?.settings["ha_url"] as? String, "http://ha.local:8123")
    }

    func testParsesPythonStreamInOneGo() throws {
        checkPythonEvents(try WyomingParser().append(pythonStream))
    }

    func testParsesPythonStreamOneByteAtATime() throws {
        let parser = WyomingParser()
        var events: [WyomingEvent] = []
        for byte in pythonStream {
            events += try parser.append(Data([byte]))
        }
        checkPythonEvents(events)
    }

    func testRoundTripWithPayload() throws {
        let original = SatelliteMessages.micChunk(Data([1, 2, 3, 4]), timestampMs: 42)
        let events = try WyomingParser().append(original.encoded())
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].type, "audio-chunk")
        XCTAssertEqual(events[0].int("rate"), 16000)
        XCTAssertEqual(events[0].int("timestamp"), 42)
        XCTAssertEqual(events[0].payload, Data([1, 2, 3, 4]))
    }

    func testEventWithoutDataHasNoDataLength() throws {
        let bytes = SatelliteMessages.played().encoded()
        let header = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        XCTAssertTrue(header.hasSuffix("\n"))
        XCTAssertFalse(header.contains("data_length"))
        XCTAssertTrue(header.contains("\"type\":\"played\""))
    }

    func testAcceptsInlineDataFromOlderPeers() throws {
        let line = Data("{\"type\":\"transcript\",\"data\":{\"text\":\"turn on the lights\"}}\n".utf8)
        let events = try WyomingParser().append(line)
        XCTAssertEqual(events.first?.string("text"), "turn on the lights")
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try WyomingParser().append(Data("GET / HTTP/1.1\n".utf8)))
    }

    func testDeviceCustomEventPutsBodyUnderData() throws {
        let event = SatelliteMessages.status(sensors: ["battery_level": 80], mediaPlaying: true)
        let parsed = try XCTUnwrap(try WyomingParser().append(event.encoded()).first)
        XCTAssertEqual(parsed.string("event_type"), "status")
        let body = try XCTUnwrap(parsed.dict("data"))
        XCTAssertEqual((body["sensors"] as? [String: Any])?["battery_level"] as? Int, 80)
        XCTAssertEqual((body["media_player"] as? [String: Any])?["playing"] as? Bool, true)
    }

    func testInfoMarksSatelliteInstalled() throws {
        let parsed = try XCTUnwrap(try WyomingParser().append(
            SatelliteMessages.info(name: "Kitchen iPad", appVersion: "0.1.0").encoded()
        ).first)
        let satellite = try XCTUnwrap(parsed.dict("satellite"))
        XCTAssertEqual(satellite["installed"] as? Bool, true)
        XCTAssertEqual(satellite["name"] as? String, "Kitchen iPad")
        // Fields the Python dataclasses require
        for key in ["attribution", "description", "version"] {
            XCTAssertNotNil(satellite[key], key)
        }
    }
}

final class MicResamplerTests: XCTestCase {
    private func run(_ resampler: MicResampler, _ samples: [Float]) -> [Int16] {
        let data = samples.withUnsafeBufferPointer { resampler.process($0) }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }

    func testDownsamples48kTo16k() {
        let out = run(MicResampler(inputRate: 48_000), [Float](repeating: 0.5, count: 4800))
        XCTAssertEqual(out.count, 1600)
        XCTAssertEqual(Double(out[0]), Double(Int16.max) * 0.5, accuracy: 1)
    }

    func testFractionalRatioGivesExpectedLength() {
        let out = run(MicResampler(inputRate: 44_100), [Float](repeating: 0, count: 44_100))
        XCTAssertEqual(Double(out.count), 16_000, accuracy: 1)
    }

    func testSplitBuffersMatchOneBuffer() {
        let input = (0..<4800).map { Float(sin(Double($0) / 7)) }
        let whole = run(MicResampler(inputRate: 48_000), input)

        let split = MicResampler(inputRate: 48_000)
        var pieces: [Int16] = []
        var i = 0
        for size in [1, 13, 256, 1000, 7, 3133] where i < input.count {
            let end = min(input.count, i + size)
            pieces += run(split, Array(input[i..<end]))
            i = end
        }
        pieces += run(split, Array(input[i...]))
        XCTAssertEqual(pieces, whole)
    }

    func testClampsLoudInput() {
        let resampler = MicResampler(inputRate: 16_000)
        resampler.gain = 4
        let out = run(resampler, [0.9, -0.9])
        XCTAssertEqual(out, [Int16.max, -Int16.max])
    }

    func testInt16ToFloat() {
        var samples: [Int16] = [0, 16384, -32768]
        let data = Data(bytes: &samples, count: 6)
        XCTAssertEqual(PCM.int16ToFloat(data), [0, 0.5, -1])
    }
}
