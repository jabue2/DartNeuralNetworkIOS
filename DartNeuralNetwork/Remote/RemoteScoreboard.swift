import Combine
import Foundation

/// Serves the game as a live web page on the local Wi-Fi, so a laptop, tablet or TV can show the
/// scoreboard and correct darts. The phone stays the camera and the place where the game lives;
/// the page only sends the same actions as the buttons on the game screen.
///
/// The address contains a random key (`http://192.168.1.20:8180/k3f9x2`): anyone on the Wi-Fi
/// without it gets nothing. "New link" replaces the key and drops pages opened with the old one.
@MainActor
final class RemoteScoreboard: ObservableObject {
    enum State: Equatable {
        case off
        case starting
        case running(port: UInt16)
        case failed(String)
    }

    @Published private(set) var state: State = .off
    /// Open pages that receive live updates.
    @Published private(set) var viewers = 0
    /// The phone's Wi-Fi (or hotspot) address, nil without a local network.
    @Published private(set) var address: String?
    @Published private(set) var key: String

    var isOn: Bool { state != .off }

    /// The address to open in a browser, once the server runs and the phone has a local address.
    var url: URL? {
        guard case .running(let port) = state, let address else { return nil }
        return URL(string: "http://\(address):\(port)/\(key)")
    }

    /// Ports tried in order; the first free one is used.
    static let ports: [UInt16] = Array(8180...8189)
    static let keyAlphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")

    private let server = LocalHTTPServer()
    private let defaults: UserDefaults
    private let loopbackOnly: Bool
    private weak var session: GameSession?
    private var sessionChanges: AnyCancellable?
    private var broadcastScheduled = false
    private var portIndex = 0
    /// The listener was stopped because the app went to the background.
    private var suspended = false
    private let page: Data

    /// - Parameters:
    ///   - defaults: Stores whether sharing is on and the key, so a bookmarked page keeps working.
    ///   - loopbackOnly: Tests listen on 127.0.0.1 only.
    init(defaults: UserDefaults = .standard, loopbackOnly: Bool = false, addressLookup: (() -> String?)? = nil) {
        self.defaults = defaults
        self.loopbackOnly = loopbackOnly
        self.addressLookup = addressLookup ?? LocalAddress.wifi
        if let saved = defaults.string(forKey: Keys.key), Self.isValidKey(saved) {
            key = saved
        } else {
            let fresh = Self.makeKey()
            key = fresh
            defaults.set(fresh, forKey: Keys.key)
        }
        page = Bundle.main.url(forResource: "scoreboard", withExtension: "html")
            .flatMap { try? Data(contentsOf: $0) } ?? Data("Scoreboard page missing from the app".utf8)

        server.onStateChange = { [weak self] state in self?.serverStateChanged(state) }
        server.onStreamCountChange = { [weak self] count in self?.viewers = count }
        if defaults.bool(forKey: Keys.enabled) { turnOn() }
    }

    private let addressLookup: () -> String?

    // MARK: Controls

    func turnOn() {
        defaults.set(true, forKey: Keys.enabled)
        portIndex = 0
        refreshAddress()
        startServer()
    }

    func turnOff() {
        defaults.set(false, forKey: Keys.enabled)
        suspended = false
        state = .off
        server.stop()
    }

    /// Replaces the key; pages opened with the old link stop updating and cannot change the game.
    func newLink() {
        key = Self.makeKey()
        defaults.set(key, forKey: Keys.key)
        server.closeStreams()
    }

    func refreshAddress() {
        address = loopbackOnly ? "127.0.0.1" : addressLookup()
    }

    /// iOS suspends the app's sockets in the background; listen again when the app is back.
    func appBecameActive() {
        refreshAddress()
        guard suspended else { return }
        suspended = false
        if isOn { startServer() }   // same port as before, so open pages reconnect by themselves
    }

    func appMovedToBackground() {
        guard isOn else { return }
        suspended = true
        server.stop()
    }

    /// The game the page shows. A later game replaces an earlier one.
    func attach(_ session: GameSession) {
        self.session = session
        sessionChanges = session.objectWillChange.sink { [weak self] _ in self?.scheduleBroadcast() }
        scheduleBroadcast()
    }

    func detach(_ session: GameSession) {
        guard self.session === session else { return }
        self.session = nil
        sessionChanges = nil
        scheduleBroadcast()
    }

    // MARK: Requests

    var snapshot: ScoreboardSnapshot { session?.scoreboardSnapshot ?? .noGame }

    func handle(_ request: HTTPRequest) -> HTTPReply {
        let parts = request.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let first = parts.first, Self.constantTimeEqual(first, key), parts.count <= 2 else {
            return .response(status: 404, contentType: "text/html; charset=utf-8", body: Data(Self.notFoundPage.utf8))
        }
        let route = parts.count == 2 ? parts[1] : ""
        switch (request.method, route) {
        case ("GET", ""):
            return .response(status: 200, contentType: "text/html; charset=utf-8", body: page)
        case ("GET", "state"):
            return json(snapshot)
        case ("GET", "events"):
            return .eventStream(initial: encode(snapshot))
        case ("POST", "action"):
            // A plain cross-site form post cannot set this type without the browser asking first.
            guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else {
                return .text(415, "Send JSON")
            }
            guard let action = try? ScoreboardAction(json: request.body) else { return .text(400, "Unknown action") }
            guard let session else { return .text(409, "No game running") }
            session.apply(action)
            return json(snapshot)
        case (_, ""), (_, "state"), (_, "events"), (_, "action"):
            return .text(405, "Method not allowed")
        default:
            return .text(404, "Not found")
        }
    }

    // MARK: Private

    private func startServer() {
        state = .starting
        let port = Self.ports[portIndex]
        server.start(port: port, loopbackOnly: loopbackOnly) { [weak self] request in
            self?.handle(request) ?? .text(503, "Unavailable")
        }
    }

    private func serverStateChanged(_ serverState: LocalHTTPServer.State) {
        guard isOn, !suspended else { return }
        switch serverState {
        case .running(let port):
            state = .running(port: port)
        case .failed(let message):
            if state != .starting {
                // A running listener failed (network change): listen again on the same port,
                // so bookmarked pages keep working.
                startServer()
            } else if portIndex + 1 < Self.ports.count {
                // Most likely the port is taken: try the next one.
                portIndex += 1
                startServer()
            } else {
                state = .failed(message)
            }
        case .stopped:
            break
        }
    }

    /// Several changes in one run-loop turn (a dart plus the visit ending) go out as one event,
    /// built after the changes are applied (`objectWillChange` fires before them).
    private func scheduleBroadcast() {
        guard !broadcastScheduled else { return }
        broadcastScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.broadcastScheduled = false
            self.server.broadcast(self.encode(self.snapshot))
        }
    }

    private func json(_ snapshot: ScoreboardSnapshot) -> HTTPReply {
        .response(status: 200, contentType: "application/json", body: encode(snapshot))
    }

    private func encode(_ snapshot: ScoreboardSnapshot) -> Data {
        (try? JSONEncoder().encode(snapshot)) ?? Data("{}".utf8)
    }

    private enum Keys {
        static let enabled = "remote.enabled"
        static let key = "remote.key"
    }

    static func makeKey() -> String {
        String((0..<6).map { _ in keyAlphabet.randomElement()! })
    }

    static func isValidKey(_ key: String) -> Bool {
        key.count == 6 && key.allSatisfy(keyAlphabet.contains)
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let a = Array(a.utf8), b = Array(b.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static let notFoundPage = """
    <!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Darts</title>
    <body style="font:17px system-ui;margin:0;display:grid;place-items:center;min-height:100vh;text-align:center;padding:16px">
    <div><h1 style="margin:0 0 8px">Link not valid</h1>
    <p style="margin:0;opacity:.7">Open the address shown in the Darts app under “Show on another screen”.</p></div>
    """
}

/// The phone's IPv4 address on the local network.
enum LocalAddress {
    /// Wi-Fi first (`en0`), then the Personal Hotspot bridge, so a laptop on the same network can reach it.
    static func wifi() -> String? {
        var addresses: [String: String] = [:]
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  (Int32(entry.ifa_flags) & IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            addresses[String(cString: entry.ifa_name)] = String(cString: host)
        }
        if let wifi = addresses["en0"] { return wifi }
        return addresses.first { $0.key.hasPrefix("bridge") }?.value
    }
}
