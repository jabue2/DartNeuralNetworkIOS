import XCTest
import UIKit
@testable import DartNeuralNetwork

/// Records what the game asks of the detector, and lets a test send detector events.
@MainActor
private final class FakeSource: DartDetectionSource {
    var status: BoardStatus = .ready
    var onEvent: ((DetectionEvent) -> Void)?
    private(set) var waitingForRemoval = false
    private(set) var resumeCount = 0
    private(set) var resetCount = 0

    func start() {}
    func stop() {}
    func endVisit() { waitingForRemoval = true }
    func resumeVisit() { waitingForRemoval = false; resumeCount += 1 }
    func reset() { resetCount += 1 }
    func makePreviewView() -> UIView { UIView() }

    func detect(_ segment: Segment) {
        guard !waitingForRemoval else { return }   // a real detector reports nothing while waiting
        onEvent?(.dartDetected(DetectedDart(segment: segment, boardPosition: nil, confidence: 0.9)))
    }
    func clear() { waitingForRemoval = false; onEvent?(.boardCleared) }
    func endVisitByItself() { waitingForRemoval = true; onEvent?(.visitEnded) }
}

@MainActor
final class GameSessionFlowTests: XCTestCase {
    private func session(start: Int = 501, players: [String] = ["A", "B"]) -> (GameSession, FakeSource) {
        let source = FakeSource()
        let s = GameSession(rules: X01Rules(startScore: start, doubleOut: true), players: players, source: source)
        s.start()
        return (s, source)
    }

    /// Review finding 1: correcting a bust back to an open visit must let detection continue.
    func testCorrectingBustResumesDetection() {
        let (s, source) = session(start: 32, players: ["A"])
        source.detect(.single(20))
        source.detect(.triple(5))                       // 20 + 15 > 32: bust
        XCTAssertEqual(s.match.activeOutcome, .bust)
        XCTAssertTrue(source.waitingForRemoval)
        let t5 = s.match.activeVisit!.darts[1].id
        s.correct(dartID: t5, to: .single(4))           // 24 thrown, 8 left: open again
        XCTAssertEqual(s.match.activeOutcome, .open)
        XCTAssertEqual(source.resumeCount, 1)
        source.detect(.double(4))
        XCTAssertEqual(s.match.activeOutcome, .checkout)   // the leg is won once "Finish leg" is tapped
    }

    /// Review finding 1: undoing the third dart reopens the visit for detection.
    func testUndoOfThirdDartResumesDetection() {
        let (s, source) = session()
        source.detect(.single(20)); source.detect(.single(20)); source.detect(.single(1))
        XCTAssertTrue(source.waitingForRemoval)
        s.undo()
        XCTAssertEqual(s.match.activeVisit?.darts.count, 2)
        XCTAssertEqual(source.resumeCount, 1)
        source.detect(.triple(20))
        XCTAssertEqual(s.match.activeVisit?.darts.last?.segment, .triple(20))
    }

    /// Re-review finding 2: undoing a one-dart bust removes the visit and must reopen detection.
    func testUndoOfOnlyDartResumesDetection() {
        let (s, source) = session(start: 40, players: ["A", "B"])
        source.detect(.triple(20))                       // 60 > 40: bust on the first dart
        XCTAssertTrue(source.waitingForRemoval)
        s.undo()
        XCTAssertNil(s.match.activeVisit)
        XCTAssertEqual(source.resumeCount, 1)
        source.detect(.double(20))
        XCTAssertEqual(s.match.activeOutcome, .checkout)
    }

    /// Re-review finding 2: the same after the detector closed a one-dart visit by itself.
    func testUndoAfterDetectorEndedOneDartVisitResumes() {
        let (s, source) = session()
        source.detect(.single(5))
        source.endVisitByItself()
        s.undo()
        XCTAssertEqual(source.resumeCount, 1)
        source.detect(.single(20))
        XCTAssertEqual(s.match.activeVisit?.darts.map(\.segment), [.single(20)])
    }

    /// Review finding 3: a late board-clear for A's visit must not end B's visit.
    func testLateClearDoesNotEndNextPlayersVisit() {
        let (s, source) = session()
        source.detect(.single(20))
        s.next()                                         // A ends early, darts still on the board
        s.enter(.single(5))                              // B enters a dart by hand
        let bVisit = s.match.activeVisit?.id
        source.clear()                                   // A's darts are pulled now
        XCTAssertEqual(s.match.activeVisit?.id, bVisit)
        XCTAssertEqual(s.match.activeVisit?.darts.count, 1)
        XCTAssertEqual(s.match.currentPlayerIndex, 1)
    }

    /// A finished three-dart visit still moves on when its darts are pulled.
    func testClearAfterFullVisitMovesOn() {
        let (s, source) = session()
        source.detect(.single(20)); source.detect(.single(20)); source.detect(.single(20))
        XCTAssertEqual(s.match.currentPlayerIndex, 0)
        source.clear()
        XCTAssertNil(s.match.activeVisit)
        XCTAssertEqual(s.match.currentPlayerIndex, 1)
    }

    /// A visit the detector ends by itself (occluded after two darts) ends once the darts are pulled.
    func testDetectorEndedVisitEndsOnClear() {
        let (s, source) = session()
        source.detect(.single(20)); source.detect(.single(20))
        source.endVisitByItself()
        source.clear()
        XCTAssertEqual(s.match.currentPlayerIndex, 1)
        XCTAssertEqual(s.match.visits.first?.darts.count, 2)
    }

    /// Review finding 4: a picker opened on an empty slot must not add a second dart if a
    /// detection fills that slot first.
    func testPickerOnSlotFilledByDetectionReplacesInsteadOfAdding() {
        let (s, source) = session()
        let visit = s.currentVisitNumber                 // picker opens on slot 0 of a new visit
        source.detect(.single(20))                       // detection lands while the picker is open
        s.set(slot: 0, ofVisit: visit, to: .triple(20))
        XCTAssertEqual(s.match.activeVisit?.darts.map(\.segment), [.triple(20)])
    }

    /// Review finding 4: a choice for a visit that has since ended is dropped.
    func testStalePickerChoiceIsDropped() {
        let (s, source) = session()
        source.detect(.single(1))
        let visit = s.currentVisitNumber
        s.next()
        source.clear()
        s.set(slot: 1, ofVisit: visit, to: .triple(20))
        XCTAssertNil(s.match.activeVisit)
        XCTAssertEqual(s.match.visits.count, 1)
    }

    /// Review finding 5: rematch hands the board state to the detector instead of trusting it is empty.
    func testRematchResetsDetector() {
        let (s, source) = session(start: 40, players: ["A"])
        source.detect(.double(20))
        s.next()                                         // "Finish leg", darts still on the board
        XCTAssertTrue(s.match.isOver)
        s.rematch()
        XCTAssertEqual(source.resetCount, 1)
        XCTAssertFalse(s.match.isOver)
        source.clear()                                   // the winning darts are pulled: nothing to end
        XCTAssertNil(s.match.activeVisit)
        XCTAssertTrue(s.match.visits.isEmpty)
    }
}
