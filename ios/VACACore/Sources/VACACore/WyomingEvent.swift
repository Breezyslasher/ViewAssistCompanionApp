import Foundation

/// One Wyoming protocol event.
///
/// On the wire an event is a JSON header line ending in `\n`, then
/// `data_length` bytes of JSON data, then `payload_length` bytes of binary
/// payload (audio). Older peers put `data` inside the header instead; the
/// parser accepts both and merges them, as the Python `wyoming` library does.
public struct WyomingEvent {
    public var type: String
    public var data: [String: Any]
    public var payload: Data?

    /// The protocol version this app announces in every header.
    public static let protocolVersion = "1.7.1"

    public init(type: String, data: [String: Any] = [:], payload: Data? = nil) {
        self.type = type
        self.data = data
        self.payload = payload
    }

    /// Serialise the event for sending.
    public func encoded() -> Data {
        var header: [String: Any] = ["type": type, "version": Self.protocolVersion]

        var dataBytes: Data?
        if !data.isEmpty {
            // JSONSerialization only fails on values that aren't JSON
            // (dates, custom types); callers only build plain dictionaries.
            dataBytes = (try? JSONSerialization.data(withJSONObject: data, options: [])) ?? Data("{}".utf8)
            header["data_length"] = dataBytes!.count
        }
        if let payload, !payload.isEmpty {
            header["payload_length"] = payload.count
        }

        var out = (try? JSONSerialization.data(withJSONObject: header, options: [])) ?? Data()
        out.append(0x0A)
        if let dataBytes { out.append(dataBytes) }
        if let payload, !payload.isEmpty { out.append(payload) }
        return out
    }

    // MARK: Typed accessors for data fields

    public func string(_ key: String) -> String? { data[key] as? String }

    public func int(_ key: String) -> Int? {
        if let v = data[key] as? Int { return v }
        if let v = data[key] as? Double { return Int(v) }
        if let v = data[key] as? String { return Int(v) }
        return nil
    }

    public func dict(_ key: String) -> [String: Any]? { data[key] as? [String: Any] }
}

public enum WyomingParseError: Error, Equatable {
    case headerTooLong
    case invalidHeader
    case missingType
    case invalidData
}

/// Incremental parser: feed it bytes as they arrive from the socket and it
/// returns every complete event.
public final class WyomingParser {
    /// A header line longer than this means the peer isn't speaking Wyoming.
    public static let maxHeaderBytes = 1 << 20

    private var buffer = Data()
    private var pending: (type: String, data: [String: Any], dataLength: Int, payloadLength: Int)?

    public init() {}

    public func append(_ bytes: Data) throws -> [WyomingEvent] {
        buffer.append(bytes)
        var events: [WyomingEvent] = []

        while true {
            if pending == nil {
                guard let newline = buffer.firstIndex(of: 0x0A) else {
                    if buffer.count > Self.maxHeaderBytes { throw WyomingParseError.headerTooLong }
                    break
                }
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[buffer.index(after: newline)...])

                if line.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) { continue }

                guard let header = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else {
                    throw WyomingParseError.invalidHeader
                }
                guard let type = header["type"] as? String else { throw WyomingParseError.missingType }
                pending = (
                    type,
                    header["data"] as? [String: Any] ?? [:],
                    max(0, (header["data_length"] as? Int) ?? 0),
                    max(0, (header["payload_length"] as? Int) ?? 0)
                )
            }

            guard let p = pending, buffer.count >= p.dataLength + p.payloadLength else { break }

            var data = p.data
            var offset = buffer.startIndex
            if p.dataLength > 0 {
                let slice = buffer[offset..<(offset + p.dataLength)]
                guard let extra = (try? JSONSerialization.jsonObject(with: Data(slice))) as? [String: Any] else {
                    throw WyomingParseError.invalidData
                }
                data.merge(extra) { _, new in new }
                offset += p.dataLength
            }
            var payload: Data?
            if p.payloadLength > 0 {
                payload = Data(buffer[offset..<(offset + p.payloadLength)])
                offset += p.payloadLength
            }
            buffer = Data(buffer[offset...])
            pending = nil
            events.append(WyomingEvent(type: p.type, data: data, payload: payload))
        }

        return events
    }
}
