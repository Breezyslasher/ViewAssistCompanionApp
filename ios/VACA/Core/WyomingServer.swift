import Foundation
import Network
import VACACore

/// One TCP connection from Home Assistant. HA opens short ones to read the
/// device's info, and one long-lived one that runs the voice satellite.
final class WyomingConnection {
    let id = UUID()
    private let connection: NWConnection
    private let parser = WyomingParser()
    private var closed = false

    var onEvent: ((WyomingConnection, WyomingEvent) -> Void)?
    var onClose: ((WyomingConnection) -> Void)?

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    /// Address of Home Assistant, used to find its web UI when it doesn't
    /// send a URL.
    var remoteHost: String? {
        guard case let .hostPort(host, _) = connection.endpoint else { return nil }
        switch host {
        case let .ipv4(address): return "\(address)"
        case let .ipv6(address):
            // Drop any interface suffix ("%en0") and bracket it for URLs.
            let text = "\(address)".split(separator: "%").first.map(String.init) ?? "\(address)"
            // IPv4 clients on a dual-stack listener show up as ::ffff:a.b.c.d
            if text.lowercased().hasPrefix("::ffff:"), text.contains(".") {
                return String(text.dropFirst(7))
            }
            return "[\(text)]"
        case let .name(name, _): return name
        @unknown default: return nil
        }
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: .main)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                do {
                    for event in try self.parser.append(data) {
                        self.onEvent?(self, event)
                    }
                } catch {
                    Log.shared.add("Bad data from \(self.remoteHost ?? "?"): \(error). Closing.")
                    self.close()
                    return
                }
            }
            if isComplete || error != nil {
                self.close()
                return
            }
            self.receive()
        }
    }

    func send(_ event: WyomingEvent) {
        guard !closed else { return }
        connection.send(content: event.encoded(), completion: .contentProcessed { _ in })
    }

    func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?(self)
    }
}

/// Listens for Home Assistant and announces the device on the local network
/// as `_vaca._tcp`, which is what the VACA integration discovers.
final class WyomingServer {
    private var listener: NWListener?
    private var connections: [UUID: WyomingConnection] = [:]

    var onEvent: ((WyomingConnection, WyomingEvent) -> Void)?
    var onClose: ((WyomingConnection) -> Void)?
    var onStateChange: ((String) -> Void)?

    func start(port: UInt16, serviceName: String) {
        stop()
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
            let listener = try NWListener(using: parameters, on: nwPort)
            listener.service = NWListener.Service(name: serviceName, type: "_vaca._tcp")
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.onStateChange?("Listening on port \(port)")
                case let .failed(error):
                    self?.onStateChange?("Server failed: \(error)")
                    // Typically the network went away; try again shortly.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        self?.start(port: port, serviceName: serviceName)
                    }
                case let .waiting(error):
                    self?.onStateChange?("Waiting for network: \(error)")
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] nwConnection in
                guard let self else { return }
                let connection = WyomingConnection(nwConnection)
                connection.onEvent = { [weak self] conn, event in self?.onEvent?(conn, event) }
                connection.onClose = { [weak self] conn in
                    self?.connections[conn.id] = nil
                    self?.onClose?(conn)
                }
                self.connections[connection.id] = connection
                connection.start()
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            onStateChange?("Could not start server: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.close() }
        connections.removeAll()
    }
}
