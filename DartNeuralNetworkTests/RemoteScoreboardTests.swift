import Combine
import XCTest
import UIKit
@testable import DartNeuralNetwork

@MainActor
private final class QuietSource: DartDetectionSource {
    var status: BoardStatus = .ready
    var onEvent: ((DetectionEvent) -> Void)?
    func start() {}
    func stop() {}
    func endVisit() {}
    func resumeVisit() {}
    func reset() {}
    func makePreviewView() -> UIView { UIView() }
    func detect(_ segment: Segment) {
        onEvent?(.dartDetected(DetectedDart(segment: segment, boardPosition: nil, confidence: 0.9)))
    }
}

@MainActor
final class RemoteScoreboardTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() async throws {
        suiteName = "RemoteScoreboardTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func session(start: Int = 501, players: [String] = ["Alex", "Sam"]) -> (GameSession, QuietSource) {
        let source = QuietSource()
        let session = GameSession(rules: X01Rules(startScore: start, doubleOut: true), players: players, source: source)
        session.start()
        return (session, source)
    }

    private func request(_ method: String, _ path: String, body: String = "", json: Bool = true) -> HTTPRequest {
        HTTPRequest(method: method, path: path, headers: json ? ["content-type": "application/json"] : [:], body: Data(body.utf8))
    }

    private func action(_ session: GameSession, _ kind: ScoreboardAction.Kind, visit: Int? = nil) -> ScoreboardAction {
        ScoreboardAction(kind: kind, leg: session.legID.uuidString, visit: visit)
    }

    private func decode(_ reply: HTTPReply, file: StaticString = #filePath, line: UInt = #line) throws -> ScoreboardSnapshot {
        guard case let .response(status, _, body) = reply else { XCTFail("not a response", file: file, line: line); throw CancellationError() }
        XCTAssertEqual(status, 200, String(decoding: body, as: UTF8.self), file: file, line: line)
        return try JSONDecoder().decode(ScoreboardSnapshot.self, from: body)
    }

    private func status(_ reply: HTTPReply) -> Int {
        switch reply {
        case .response(let status, _, _): return status
        case .eventStream: return 200
        }
    }

    // MARK: Snapshot

    func testTheSnapshotShowsWhatThePhoneShows() throws {
        let (session, source) = session(start: 170)
        source.detect(.triple(20)); source.detect(.single(20)); source.detect(.single(20))   // 100, Alex on 70
        session.next()
        source.detect(.triple(19))                                                              // Sam 57, open

        let snapshot = session.scoreboardSnapshot
        let game = try XCTUnwrap(snapshot.game)
        XCTAssertEqual(snapshot.board, "ready")
        XCTAssertEqual(game.current, 1)
        XCTAssertEqual(game.shown, 113)
        XCTAssertEqual(game.players.map(\.remaining), [70, 113])
        XCTAssertEqual(game.players.map(\.remainingBefore), [70, 170])
        XCTAssertEqual(game.visit?.darts.map(\.label), ["T19"])
        XCTAssertEqual(game.visit?.darts.first?.ring, "treble")
        XCTAssertEqual(game.visit?.outcome, "open")
        XCTAssertEqual(game.dartsLeft, 2)
        XCTAssertEqual(game.checkout?.map(\.label), session.match.checkoutSuggestion?.map(\.label))
        XCTAssertEqual(game.recent.count, 1, "only confirmed visits are history")
        XCTAssertEqual(game.recent.first?.scored, 100)
        XCTAssertEqual(game.visitNumber, session.currentVisitNumber)
        XCTAssertNil(game.winner)
    }

    func testAShortVisitIsMarkedEndedEarly() throws {
        let (session, source) = session()
        source.detect(.single(5))
        session.next()
        let visit = try XCTUnwrap(session.scoreboardSnapshot.game?.recent.first)
        XCTAssertTrue(visit.endedEarly)
        XCTAssertEqual(visit.darts.count, 1)
    }

    // MARK: Actions

    func testActionsDecodeLikeTheButtons() throws {
        func decode(_ json: String) throws -> ScoreboardAction { try ScoreboardAction(json: Data(json.utf8)) }
        XCTAssertEqual(try decode(#"{"type":"set","leg":"L","slot":2,"visit":4,"segment":"D16"}"#),
                       ScoreboardAction(kind: .set(slot: 2, segment: .double(16)), leg: "L", visit: 4))
        XCTAssertEqual(try decode(#"{"type":"set","leg":"L","slot":0,"visit":0,"segment":"Bull"}"#).kind, .set(slot: 0, segment: .bull))
        XCTAssertEqual(try decode(#"{"type":"set","leg":"L","slot":0,"visit":0,"segment":"25"}"#).kind, .set(slot: 0, segment: .outerBull))
        XCTAssertEqual(try decode(#"{"type":"set","leg":"L","slot":0,"visit":0,"segment":"Miss"}"#).kind, .set(slot: 0, segment: .miss))
        XCTAssertEqual(try decode(#"{"type":"next","leg":"L","visit":3}"#), ScoreboardAction(kind: .next, leg: "L", visit: 3))
        XCTAssertEqual(try decode(#"{"type":"undo","leg":"L"}"#).kind, .undo)
        for bad in [#"{"type":"set","leg":"L","slot":3,"visit":0,"segment":"T20"}"#,
                    #"{"type":"set","leg":"L","slot":0,"visit":0,"segment":"T21"}"#,
                    #"{"type":"set","leg":"L","slot":0,"segment":"T20"}"#,
                    #"{"type":"next","leg":"L"}"#,
                    #"{"type":"undo"}"#,
                    #"{"type":"delete","leg":"L"}"#, "[]", "not json"] {
            XCTAssertThrowsError(try ScoreboardAction(json: Data(bad.utf8)), bad)
        }
    }

    func testEveryDartLabelTheSnapshotSendsIsAcceptedBack() {
        for segment in Segment.allScoring + [.miss] {
            XCTAssertEqual(Segment(detectorLabel: segment.label), segment, segment.label)
        }
    }

    func testAnEditForAVisitThatMovedOnIsIgnored() {
        let (session, source) = session()
        source.detect(.single(20))
        let staleVisit = session.currentVisitNumber
        session.next()
        source.detect(.single(1))
        session.apply(action(session, .set(slot: 0, segment: .triple(20)), visit: staleVisit))
        XCTAssertEqual(session.match.activeVisit?.darts.map(\.segment), [.single(1)])
    }

    /// Review finding: a double click on Next must not skip the next player's visit.
    func testARepeatedNextIsIgnored() {
        let (session, source) = session()
        source.detect(.single(20))
        let next = action(session, .next, visit: session.currentVisitNumber)
        session.apply(next)
        session.apply(next)
        XCTAssertEqual(session.match.visits.count, 1, "the second click named a visit that is already over")
        XCTAssertEqual(session.match.currentPlayerIndex, 1)
    }

    /// Review finding: a picker left open on an earlier leg must not change the new one.
    func testAnEditFromAnEarlierLegIsIgnored() {
        let (session, source) = session(start: 40, players: ["A"])
        source.detect(.double(20))
        session.next()
        let oldLeg = action(session, .set(slot: 0, segment: .triple(20)), visit: 0)
        session.apply(action(session, .rematch))
        session.apply(oldLeg)
        XCTAssertTrue(session.match.visits.isEmpty)
    }

    func testRematchOnlyAfterTheLegIsWon() {
        let (session, source) = session(start: 40, players: ["A"])
        source.detect(.single(20))
        session.apply(action(session, .rematch))
        XCTAssertEqual(session.match.visits.count, 1, "a stray rematch must not wipe a game in progress")
        source.detect(.double(10))
        session.next()
        XCTAssertTrue(session.match.isOver)
        session.apply(action(session, .rematch))
        XCTAssertTrue(session.match.visits.isEmpty)
    }

    // MARK: Routes

    func testOnlyTheKeyOpensTheScoreboard() throws {
        let remote = RemoteScoreboard(defaults: defaults, loopbackOnly: true)
        let (session, _) = session()
        remote.attach(session)
        let key = remote.key

        XCTAssertEqual(status(remote.handle(request("GET", "/"))), 404)
        XCTAssertEqual(status(remote.handle(request("GET", "/wrong1/state"))), 404)
        XCTAssertEqual(status(remote.handle(request("POST", "/wrong1/action", body: #"{"type":"undo"}"#))), 404)
        XCTAssertEqual(status(remote.handle(request("GET", "/\(key)/state/extra"))), 404)

        guard case let .response(200, type, page) = remote.handle(request("GET", "/\(key)")) else { return XCTFail("no page") }
        XCTAssertTrue(type.hasPrefix("text/html"))
        XCTAssertTrue(String(decoding: page, as: UTF8.self).contains("<title>Darts Scoreboard</title>"), "page bundled with the app")
        XCTAssertNotNil(try decode(remote.handle(request("GET", "/\(key)/state"))).game)
        XCTAssertEqual(status(remote.handle(request("GET", "/\(key)/action"))), 405)
        XCTAssertEqual(status(remote.handle(request("POST", "/\(key)/action", body: #"{"type":"undo","leg":"x"}"#, json: false))), 415,
                       "a plain cross-site form post is refused")
    }

    func testANewLinkLocksOutTheOldOne() {
        let remote = RemoteScoreboard(defaults: defaults, loopbackOnly: true)
        let old = remote.key
        remote.newLink()
        XCTAssertNotEqual(remote.key, old)
        XCTAssertEqual(status(remote.handle(request("GET", "/\(old)/state"))), 404)
        XCTAssertEqual(RemoteScoreboard(defaults: defaults, loopbackOnly: true).key, remote.key, "the link survives a restart")
    }

    func testActionsChangeTheGame() throws {
        let remote = RemoteScoreboard(defaults: defaults, loopbackOnly: true)
        let (session, source) = session()
        remote.attach(session)
        source.detect(.single(20))
        let visit = session.currentVisitNumber
        let leg = session.legID.uuidString

        let corrected = try decode(remote.handle(request("POST", "/\(remote.key)/action",
                                                         body: #"{"type":"set","leg":"\#(leg)","slot":0,"visit":\#(visit),"segment":"T20"}"#)))
        XCTAssertEqual(corrected.game?.visit?.darts.map(\.label), ["T20"])
        XCTAssertEqual(corrected.game?.visit?.darts.first?.manual, true)

        let added = try decode(remote.handle(request("POST", "/\(remote.key)/action",
                                                     body: #"{"type":"set","leg":"\#(leg)","slot":1,"visit":\#(visit),"segment":"D5"}"#)))
        XCTAssertEqual(added.game?.visit?.darts.map(\.label), ["T20", "D5"])

        let next = try decode(remote.handle(request("POST", "/\(remote.key)/action", body: #"{"type":"next","leg":"\#(leg)","visit":\#(visit)}"#)))
        XCTAssertEqual(next.game?.current, 1)
        XCTAssertEqual(next.game?.players.first?.remaining, 501 - 70)

        let undone = try decode(remote.handle(request("POST", "/\(remote.key)/action", body: #"{"type":"undo","leg":"\#(leg)"}"#)))
        XCTAssertEqual(undone.game?.current, 0)
        XCTAssertEqual(status(remote.handle(request("POST", "/\(remote.key)/action", body: #"{"type":"nope"}"#))), 400)
    }

    func testWithoutAGameThePageSaysSo() throws {
        let remote = RemoteScoreboard(defaults: defaults, loopbackOnly: true)
        let (session, _) = session()
        remote.attach(session)
        remote.detach(session)
        XCTAssertNil(try decode(remote.handle(request("GET", "/\(remote.key)/state"))).game)
        XCTAssertEqual(status(remote.handle(request("POST", "/\(remote.key)/action", body: #"{"type":"next","leg":"x","visit":0}"#))), 409)
    }

    // MARK: Over the network

    /// The real server on 127.0.0.1: page, state, an action, and a live event after a dart.
    func testALiveStreamFollowsTheGame() async throws {
        let remote = RemoteScoreboard(defaults: defaults, loopbackOnly: true)
        let (session, source) = session()
        remote.attach(session)
        remote.turnOn()
        defer { remote.turnOff() }

        let url = try await waitForURL(remote)
        XCTAssertTrue(url.absoluteString.hasPrefix("http://127.0.0.1:818"))

        let (pageData, pageResponse) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((pageResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: pageData, as: UTF8.self).contains("EventSource"))

        var wrong = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        wrong.path = "/zzzzzz/state"
        let (_, wrongResponse) = try await URLSession.shared.data(from: wrong.url!)
        XCTAssertEqual((wrongResponse as? HTTPURLResponse)?.statusCode, 404)

        // Live stream: the first event is the current game, the next one follows a detected dart.
        let (bytes, streamResponse) = try await URLSession.shared.bytes(from: url.appendingPathComponent("events"))
        XCTAssertEqual((streamResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), "text/event-stream")
        var events = bytes.lines.filter { $0.hasPrefix("data: ") }.map { line in
            try JSONDecoder().decode(ScoreboardSnapshot.self, from: Data(line.dropFirst(6).utf8))
        }.makeAsyncIterator()

        let first = try await events.next()
        XCTAssertEqual(first?.game?.visit?.darts.count ?? 0, 0)
        try await waitUntil { remote.viewers == 1 }

        source.detect(.triple(20))
        let afterDart = try await events.next()
        XCTAssertEqual(afterDart?.game?.visit?.darts.map(\.label), ["T20"])

        // An action over HTTP reaches the game and the stream.
        var post = URLRequest(url: url.appendingPathComponent("action"))
        post.httpMethod = "POST"
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        post.httpBody = Data(#"{"type":"undo","leg":"\#(session.legID.uuidString)"}"#.utf8)
        let (_, postResponse) = try await URLSession.shared.data(for: post)
        XCTAssertEqual((postResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertNil(session.match.activeVisit)
        let afterUndo = try await events.next()
        XCTAssertNil(afterUndo?.game?.visit)
    }

    private func waitForURL(_ remote: RemoteScoreboard) async throws -> URL {
        try await waitUntil { remote.url != nil }
        return try XCTUnwrap(remote.url)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw Timeout() }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private struct Timeout: Error {}
}
