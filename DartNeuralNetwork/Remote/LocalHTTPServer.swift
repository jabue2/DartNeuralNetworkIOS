import Foundation
import Network

struct HTTPRequest {
    var method: String
    /// Path without the query string, percent-decoded, e.g. "/k3f9x2/state".
    var path: String
    /// Header names in lower case.
    var headers: [String: String]
    var body: Data
}

enum HTTPReply {
    case response(status: Int, contentType: String, body: Data)
    /// Keeps the connection open as a Server-Sent Events stream; `initial` is the first event's data.
    case eventStream(initial: Data)

    static func text(_ status: Int, _ text: String) -> HTTPReply {
        .response(status: status, contentType: "text/plain; charset=utf-8", body: Data(text.utf8))
    }
}

/// A minimal HTTP/1.1 server on the local network for the web scoreboard: one request per
/// connection, plus long-lived Server-Sent Events streams that `broadcast` writes to.
///
/// All connection state lives on `queue`. The handler runs on the main actor, where the game is.
final class LocalHTTPServer {
    typealias Handler = @MainActor (HTTPRequest) -> HTTPReply

    enum State: Equatable {
        case stopped
        case running(port: UInt16)
        case failed(String)
    }

    /// Called on the main queue.
    var onStateChange: ((State) -> Void)?
    /// Number of open event streams (connected scoreboards). Called on the main queue.
    var onStreamCountChange: ((Int) -> Void)?

    /// Requests larger than this are refused; the page only ever sends tiny JSON bodies.
    static let maxRequestBytes = 16 * 1024

    private let queue = DispatchQueue(label: "scoreboard.http")
    private var listener: NWListener?
    private var streams: [ObjectIdentifier: NWConnection] = [:]
    /// Connections whose request has not fully arrived yet.
    private var pending = Set<ObjectIdentifier>()
    /// Every open connection, so stopping cuts requests still arriving or being answered too.
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    /// Writes not yet taken by the network, per stream. A page that stops reading is dropped.
    private var unsent: [ObjectIdentifier: Int] = [:]
    /// Bumped on every stop, so a reply computed for an earlier server run is never sent.
    private var generation = 0
    static let maxUnsentWrites = 8
    private var heartbeat: DispatchSourceTimer?
    private var handler: Handler?

    deinit {
        listener?.cancel()
        streams.values.forEach { $0.cancel() }
        heartbeat?.cancel()
    }

    /// Starts listening on `port` on all interfaces. Stops a previous listener first.
    /// `loopbackOnly` is for tests.
    func start(port: UInt16, loopbackOnly: Bool = false, handler: @escaping Handler) {
        queue.async { [self] in
            stopOnQueue()
            self.handler = handler
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            if loopbackOnly {
                parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
            }
            let listener: NWListener
            do {
                listener = loopbackOnly ? try NWListener(using: parameters)
                                        : try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            } catch {
                report(.failed(error.localizedDescription))
                return
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    self.report(.running(port: listener.port?.rawValue ?? port))
                case .failed(let error):
                    self.stopOnQueue()
                    self.report(.failed(error.localizedDescription))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            self.listener = listener
            listener.start(queue: queue)
            startHeartbeat()
        }
    }

    func stop() {
        queue.async { [self] in
            let wasRunning = listener != nil
            stopOnQueue()
            if wasRunning { report(.stopped) }
        }
    }

    /// Sends one event to every open stream.
    func broadcast(_ data: Data) {
        queue.async { [self] in
            let event = Self.event(data)
            for connection in streams.values { write(event, to: connection) }
        }
    }

    /// Closes every open stream (after the link changed, so old pages lose access).
    func closeStreams() {
        queue.async { [self] in
            let open = Array(streams.values)
            streams.removeAll()
            open.forEach { $0.cancel() }
            reportStreamCount()
        }
    }

    // MARK: - Queue-confined

    private func stopOnQueue() {
        generation += 1
        handler = nil
        let all = Array(connections.values)
        connections.removeAll()
        pending.removeAll()
        unsent.removeAll()
        all.forEach { $0.cancel() }
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        heartbeat?.cancel()
        heartbeat = nil
        let open = Array(streams.values)
        streams.removeAll()
        open.forEach { $0.cancel() }
        reportStreamCount()
    }

    private func report(_ state: State) {
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(state) }
    }

    private func reportStreamCount() {
        let count = streams.count
        DispatchQueue.main.async { [weak self] in self?.onStreamCountChange?(count) }
    }

    /// A comment line every 15 s finds streams whose browser went away without closing.
    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            for connection in self.streams.values { self.write(Data(": ping\n\n".utf8), to: connection) }
        }
        timer.resume()
        heartbeat = timer
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .failed, .cancelled:
                self.pending.remove(ObjectIdentifier(connection))
                self.connections.removeValue(forKey: ObjectIdentifier(connection))
                self.unsent.removeValue(forKey: ObjectIdentifier(connection))
                if self.streams.removeValue(forKey: ObjectIdentifier(connection)) != nil { self.reportStreamCount() }
            default:
                break
            }
        }
        let id = ObjectIdentifier(connection)
        pending.insert(id)
        connections[id] = connection
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
        // A client that never finishes its request is dropped.
        queue.asyncAfter(deadline: .now() + 10) { [weak self, weak connection] in
            // `connection` alive means `id` still names it (an identifier is only reused after deallocation).
            guard let self, let connection, self.pending.remove(id) != nil else { return }
            connection.cancel()
        }
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxRequestBytes) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.count > Self.maxRequestBytes {
                self.send(.text(413, "Request too large"), on: connection)
                return
            }
            switch Self.parse(buffer) {
            case .complete(let request):
                self.pending.remove(ObjectIdentifier(connection))
                self.handle(request, on: connection)
            case .invalid:
                self.send(.text(400, "Bad request"), on: connection)
            case .incomplete:
                if isComplete || error != nil { connection.cancel() } else { self.receive(on: connection, buffer: buffer) }
            }
        }
    }

    private func handle(_ request: HTTPRequest, on connection: NWConnection) {
        guard let handler else { connection.cancel(); return }
        let run = generation
        DispatchQueue.main.async { [weak self] in
            // The server may have stopped while this request waited for the main queue.
            guard let self, self.queue.sync(execute: { self.generation == run }) else { connection.cancel(); return }
            let reply = MainActor.assumeIsolated { handler(request) }
            self.queue.async {
                guard self.generation == run else { connection.cancel(); return }
                self.send(reply, on: connection)
            }
        }
    }

    private func send(_ reply: HTTPReply, on connection: NWConnection) {
        switch reply {
        case let .response(status, contentType, body):
            let head = Self.head(status: status, headers: [
                "Content-Type": contentType,
                "Content-Length": "\(body.count)",
                "Cache-Control": "no-store",
                "Connection": "close",
            ])
            connection.send(content: head + body, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
        case .eventStream(let initial):
            let head = Self.head(status: 200, headers: [
                "Content-Type": "text/event-stream",
                "Cache-Control": "no-store",
                "Connection": "keep-alive",
            ])
            streams[ObjectIdentifier(connection)] = connection
            reportStreamCount()
            write(head + Self.event(initial), to: connection)
            watchForClose(connection)
        }
    }

    /// A browser closing the page ends the stream from its side.
    private func watchForClose(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil { connection.cancel() } else { self?.watchForClose(connection) }
        }
    }

    private func write(_ data: Data, to connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        let waiting = (unsent[id] ?? 0) + 1
        guard waiting <= Self.maxUnsentWrites else {
            connection.cancel()   // the page stopped reading; it reconnects and gets the current state
            return
        }
        unsent[id] = waiting
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let self, let count = self.unsent[id] { self.unsent[id] = count - 1 }
            if error != nil { connection.cancel() }
        })
    }

    // MARK: - HTTP text

    enum ParseResult {
        case incomplete
        case invalid
        case complete(HTTPRequest)
    }

    static func parse(_ data: Data) -> ParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = data.range(of: separator) else { return .incomplete }
        guard let headText = String(data: data[..<end.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = headText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length: Int
        if let raw = headers["content-length"] {
            guard let value = Int(raw), value >= 0, value <= maxRequestBytes else { return .invalid }
            length = value
        } else {
            length = 0
        }
        let bodyStart = end.upperBound
        guard data.count - bodyStart >= length else { return .incomplete }
        let target = String(requestLine[1])
        let rawPath = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "/"
        return .complete(HTTPRequest(method: String(requestLine[0]),
                                     path: rawPath.removingPercentEncoding ?? rawPath,
                                     headers: headers,
                                     body: Data(data[bodyStart..<(bodyStart + length)])))
    }

    private static func head(status: Int, headers: [String: String]) -> Data {
        var text = "HTTP/1.1 \(status) \(reason(status))\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { text += "\(name): \(value)\r\n" }
        return Data((text + "\r\n").utf8)
    }

    private static func event(_ data: Data) -> Data {
        // JSON has no raw newlines, so one `data:` line carries the whole event.
        Data("data: ".utf8) + data + Data("\n\n".utf8)
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}
