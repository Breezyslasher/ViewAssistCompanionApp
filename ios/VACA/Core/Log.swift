import Foundation

/// A short in-app log, shown in Settings and sent to Home Assistant when it
/// asks for logs (the `get-logs` event).
final class Log: ObservableObject {
    static let shared = Log()

    @Published private(set) var lines: [String] = []
    private let maxLines = 500
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func add(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)"
        #if DEBUG
        print(line)
        #endif
        if Thread.isMainThread {
            append(line)
        } else {
            DispatchQueue.main.async { self.append(line) }
        }
    }

    private func append(_ line: String) {
        lines.append(line)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
    }

    var text: String { lines.joined(separator: "\n") }
}
