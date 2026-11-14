import XCTest
@testable import DartNeuralNetwork

@MainActor
final class ScreenAwakeTests: XCTestCase {
    private var calls: [Bool] = []
    private var original: ((Bool) -> Void)!

    override func setUp() async throws {
        original = ScreenAwake.apply
        while ScreenAwake.requests > 0 { ScreenAwake.release() }
        calls = []
        ScreenAwake.apply = { [unowned self] in self.calls.append($0) }
    }

    override func tearDown() async throws {
        while ScreenAwake.requests > 0 { ScreenAwake.release() }
        ScreenAwake.apply = original
    }

    func testTheDisplayMaySleepOnlyAfterTheLastRequestEnds() {
        ScreenAwake.acquire()          // game screen
        ScreenAwake.acquire()          // camera check overlapping during a transition
        ScreenAwake.release()
        XCTAssertEqual(calls, [true], "one screen still watches the board")
        ScreenAwake.release()
        XCTAssertEqual(calls, [true, false])
    }

    func testAnExtraReleaseDoesNotUnderflow() {
        ScreenAwake.release()
        ScreenAwake.acquire()
        XCTAssertEqual(calls, [true], "a stray release must not swallow the next request")
    }
}
