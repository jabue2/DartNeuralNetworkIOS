import XCTest
@testable import DartNeuralNetwork

final class SegmentTests: XCTestCase {
    func testPoints() {
        XCTAssertEqual(Segment.single(20).points, 20)
        XCTAssertEqual(Segment.double(16).points, 32)
        XCTAssertEqual(Segment.triple(19).points, 57)
        XCTAssertEqual(Segment.outerBull.points, 25)
        XCTAssertEqual(Segment.bull.points, 50)
        XCTAssertEqual(Segment.miss.points, 0)
    }

    func testDoublesIncludeBullOnly() {
        XCTAssertTrue(Segment.double(1).isDouble)
        XCTAssertTrue(Segment.bull.isDouble)
        XCTAssertFalse(Segment.outerBull.isDouble)
        XCTAssertFalse(Segment.triple(20).isDouble)
    }

    func testParsesDetectorLabels() {
        XCTAssertEqual(Segment(detectorLabel: "T20"), .triple(20))
        XCTAssertEqual(Segment(detectorLabel: "D16"), .double(16))
        XCTAssertEqual(Segment(detectorLabel: "S5"), .single(5))
        XCTAssertEqual(Segment(detectorLabel: "DB"), .bull)
        XCTAssertEqual(Segment(detectorLabel: "SB"), .outerBull)
        XCTAssertEqual(Segment(detectorLabel: "miss"), .miss)
        XCTAssertEqual(Segment(detectorLabel: "0"), .miss)
        XCTAssertEqual(Segment(detectorLabel: "Outer Bull"), .outerBull)
        XCTAssertNil(Segment(detectorLabel: "T21"))
        XCTAssertNil(Segment(detectorLabel: "X5"))
    }

    func testAllScoringHas62Segments() {
        XCTAssertEqual(Segment.allScoring.count, 62)
        XCTAssertEqual(Set(Segment.allScoring).count, 62)
    }
}

final class BoardGeometryTests: XCTestCase {
    func testCentreOfEachBedScoresThatBed() {
        for segment in Segment.allScoring {
            let point = BoardGeometry.point(in: segment)!
            XCTAssertEqual(BoardGeometry.segment(at: point), segment, "\(segment)")
        }
    }

    func testOrientation() {
        XCTAssertEqual(BoardGeometry.segment(at: BoardPoint(x: 0, y: -0.5)), .single(20))   // top
        XCTAssertEqual(BoardGeometry.segment(at: BoardPoint(x: 0.5, y: 0)), .single(6))     // right
        XCTAssertEqual(BoardGeometry.segment(at: BoardPoint(x: 0, y: 0.5)), .single(3))     // bottom
        XCTAssertEqual(BoardGeometry.segment(at: BoardPoint(x: -0.5, y: 0)), .single(11))   // left
        XCTAssertEqual(BoardGeometry.segment(at: BoardPoint(x: 0, y: -1.05)), .miss)
    }
}

final class VisitEvaluationTests: XCTestCase {
    let doubleOut = X01Rules(startScore: 501, doubleOut: true)
    let straightOut = X01Rules(startScore: 501, doubleOut: false)

    func testThreeDartsScore() {
        let result = X01.evaluate([.triple(20), .triple(20), .triple(20)], from: 501, rules: doubleOut)
        XCTAssertEqual(result, VisitEvaluation(outcome: .scored, scored: 180, endIndex: 2))
    }

    func testOpenVisit() {
        let result = X01.evaluate([.single(20)], from: 501, rules: doubleOut)
        XCTAssertEqual(result.outcome, .open)
        XCTAssertEqual(result.scored, 20)
    }

    func testBustBelowZero() {
        let result = X01.evaluate([.single(20), .triple(5)], from: 32, rules: doubleOut)
        XCTAssertEqual(result, VisitEvaluation(outcome: .bust, scored: 0, endIndex: 1))
    }

    func testBustLeavingOneOnDoubleOut() {
        XCTAssertEqual(X01.evaluate([.single(19)], from: 20, rules: doubleOut).outcome, .bust)
        XCTAssertEqual(X01.evaluate([.single(19)], from: 20, rules: straightOut).outcome, .open)
    }

    func testFinishingOnSingleIsBustOnDoubleOut() {
        XCTAssertEqual(X01.evaluate([.single(20)], from: 20, rules: doubleOut).outcome, .bust)
        XCTAssertEqual(X01.evaluate([.single(20)], from: 20, rules: straightOut).outcome, .checkout)
    }

    func testCheckoutOnDoubleAndBull() {
        XCTAssertEqual(X01.evaluate([.triple(19), .double(12)], from: 81, rules: doubleOut),
                       VisitEvaluation(outcome: .checkout, scored: 81, endIndex: 1))
        XCTAssertEqual(X01.evaluate([.bull], from: 50, rules: doubleOut).outcome, .checkout)
        XCTAssertEqual(X01.evaluate([.outerBull, .outerBull], from: 50, rules: doubleOut).outcome, .bust)
    }
}

final class X01MatchTests: XCTestCase {
    private func dart(_ s: Segment) -> Dart { Dart(segment: s) }

    func testTurnOrderAndRemaining() {
        var match = X01Match(rules: .standard, players: ["A", "B"])
        XCTAssertEqual(match.currentPlayerIndex, 0)
        for s in [Segment.triple(20), .triple(20), .triple(20)] { match.add(dart(s)) }
        XCTAssertEqual(match.activeOutcome, .scored)
        XCTAssertEqual(match.remaining(for: 0), 321)
        // Still A's visit on screen until it is confirmed.
        XCTAssertEqual(match.currentPlayerIndex, 0)
        match.confirmVisit()
        XCTAssertEqual(match.currentPlayerIndex, 1)
        XCTAssertNil(match.activeVisit)
    }

    func testAddingAfterFinishedVisitMovesOn() {
        var match = X01Match(rules: .standard, players: ["A", "B"])
        for _ in 0..<3 { match.add(dart(.single(20))) }
        match.add(dart(.single(1)))   // B throws before A's visit was confirmed
        XCTAssertEqual(match.currentPlayerIndex, 1)
        XCTAssertEqual(match.remaining(for: 1), 500)
        XCTAssertEqual(match.remaining(for: 0), 441)
    }

    func testBustRestoresScore() {
        var match = X01Match(rules: X01Rules(startScore: 40, doubleOut: true), players: ["A"])
        match.add(dart(.single(20)))
        XCTAssertEqual(match.remaining(for: 0), 20)
        XCTAssertEqual(match.add(dart(.triple(20))), .bust)
        XCTAssertEqual(match.remaining(for: 0), 40)
        XCTAssertEqual(match.dartsLeftInVisit, 0)
        match.confirmVisit()
        XCTAssertEqual(match.remaining(for: 0), 40)
    }

    func testCheckoutWinsAfterConfirm() {
        var match = X01Match(rules: X01Rules(startScore: 81, doubleOut: true), players: ["A", "B"])
        match.add(dart(.triple(19)))
        XCTAssertEqual(match.add(dart(.double(12))), .checkout)
        XCTAssertFalse(match.isOver, "a finish can still be corrected before it is confirmed")
        match.endVisit()
        XCTAssertTrue(match.isOver)
        XCTAssertEqual(match.winnerIndex, 0)
        XCTAssertEqual(match.add(dart(.single(1))), .checkout, "no darts after the leg is won")
        XCTAssertEqual(match.visits.count, 1)
    }

    func testEndVisitEarlyCountsMissingDartsAsMisses() {
        var match = X01Match(rules: .standard, players: ["A", "B"])
        match.add(dart(.single(20)))
        match.endVisit()
        XCTAssertEqual(match.currentPlayerIndex, 1)
        XCTAssertEqual(match.stats(for: 0).dartsThrown, 3)
        // Ending a visit with no darts at all is a visit of three misses.
        match.endVisit()
        XCTAssertEqual(match.currentPlayerIndex, 0)
        XCTAssertEqual(match.remaining(for: 1), 501)
    }

    func testUndoReversesOneActionAtATime() {
        var match = X01Match(rules: .standard, players: ["A", "B"])
        match.add(dart(.triple(20)))
        match.add(dart(.single(5)))
        match.endVisit()
        XCTAssertEqual(match.currentPlayerIndex, 1)

        match.undo()   // reopen A's visit
        XCTAssertEqual(match.currentPlayerIndex, 0)
        XCTAssertEqual(match.activeVisit?.darts.count, 2)
        XCTAssertEqual(match.activeOutcome, .open)

        match.undo()   // remove S5
        XCTAssertEqual(match.remaining(for: 0), 441)
        match.undo()   // remove T20, visit gone
        XCTAssertNil(match.activeVisit)
        XCTAssertFalse(match.canUndo)
        XCTAssertEqual(match.remaining(for: 0), 501)
    }

    func testUndoWinningDartReopensLeg() {
        var match = X01Match(rules: X01Rules(startScore: 40, doubleOut: true), players: ["A"])
        match.add(dart(.double(20)))
        match.endVisit()
        XCTAssertTrue(match.isOver)
        match.undo()
        XCTAssertFalse(match.isOver)
        XCTAssertEqual(match.activeOutcome, .checkout)
        match.undo()
        XCTAssertEqual(match.remaining(for: 0), 40)
    }

    func testCorrectionRescoresVisit() {
        var match = X01Match(rules: X01Rules(startScore: 32, doubleOut: true), players: ["A"])
        let first = Dart(segment: .single(20), confidence: 0.9)
        match.add(first)
        let second = Dart(segment: .triple(5), confidence: 0.5)
        XCTAssertEqual(match.add(second), .bust)
        // Detector misread: it was a single 4, leaving D4.
        XCTAssertEqual(match.replaceDart(id: second.id, with: .single(4)), .open)
        XCTAssertEqual(match.remaining(for: 0), 8)
        XCTAssertNil(match.activeVisit?.darts[1].confidence, "corrected darts count as manual")
        XCTAssertEqual(match.checkoutSuggestion, [.double(4)])
    }

    func testCorrectionToFinishDropsLaterDarts() {
        var match = X01Match(rules: X01Rules(startScore: 40, doubleOut: true), players: ["A"])
        let first = Dart(segment: .single(20))
        match.add(first)
        match.add(dart(.single(10)))
        XCTAssertEqual(match.replaceDart(id: first.id, with: .double(20)), .checkout)
        XCTAssertEqual(match.activeVisit?.darts.count, 1)
    }

    func testStats() {
        var match = X01Match(rules: X01Rules(startScore: 101, doubleOut: true), players: ["A"])
        for s in [Segment.triple(20), .single(1), .single(20)] { match.add(dart(s)) }   // 81, leaves 20
        match.confirmVisit()
        for s in [Segment.single(10), .double(5)] { match.add(dart(s)) }                // 10 → D5 out
        match.endVisit()

        let stats = match.stats(for: 0)
        XCTAssertEqual(stats.pointsScored, 101)
        XCTAssertEqual(stats.dartsThrown, 5)
        XCTAssertEqual(stats.threeDartAverage, 101.0 / 5 * 3, accuracy: 0.001)
        XCTAssertEqual(stats.bestVisit, 81)
        XCTAssertEqual(stats.checkout, 20)
        // On 40 (D20), 20 (D10) and 10 (D5): three darts at a double.
        XCTAssertEqual(stats.dartsAtDouble, 3)
        XCTAssertEqual(stats.checkoutRate ?? 0, 1.0 / 3, accuracy: 0.001)
    }

    func testBustCountsThreeDartsAndNoPoints() {
        var match = X01Match(rules: X01Rules(startScore: 40, doubleOut: true), players: ["A"])
        match.add(dart(.triple(20)))
        match.confirmVisit()
        let stats = match.stats(for: 0)
        XCTAssertEqual(stats.dartsThrown, 3)
        XCTAssertEqual(stats.pointsScored, 0)
        XCTAssertEqual(stats.threeDartAverage, 0)
    }
}

final class CheckoutCalculatorTests: XCTestCase {
    func testWellKnownRoutes() {
        XCTAssertEqual(CheckoutCalculator.suggestion(for: 170, dartsLeft: 3, doubleOut: true), [.triple(20), .triple(20), .bull])
        XCTAssertEqual(CheckoutCalculator.suggestion(for: 141, dartsLeft: 3, doubleOut: true), [.triple(20), .triple(19), .double(12)])
        XCTAssertEqual(CheckoutCalculator.suggestion(for: 100, dartsLeft: 3, doubleOut: true), [.triple(20), .double(20)])
        XCTAssertEqual(CheckoutCalculator.suggestion(for: 81, dartsLeft: 2, doubleOut: true), [.triple(19), .double(12)])
        XCTAssertEqual(CheckoutCalculator.suggestion(for: 60, dartsLeft: 3, doubleOut: true), [.single(20), .double(20)])
        XCTAssertEqual(CheckoutCalculator.suggestion(for: 50, dartsLeft: 1, doubleOut: true), [.bull])
        XCTAssertEqual(CheckoutCalculator.suggestion(for: 32, dartsLeft: 1, doubleOut: true), [.double(16)])
    }

    func testBogeyNumbersHaveNoRoute() {
        for score in [169, 168, 166, 165, 163, 162, 159] {
            XCTAssertNil(CheckoutCalculator.suggestion(for: score, dartsLeft: 3, doubleOut: true), "\(score)")
        }
        XCTAssertNil(CheckoutCalculator.suggestion(for: 171, dartsLeft: 3, doubleOut: true))
        XCTAssertNil(CheckoutCalculator.suggestion(for: 1, dartsLeft: 3, doubleOut: true))
    }

    func testRespectsDartsLeft() {
        XCTAssertNil(CheckoutCalculator.suggestion(for: 100, dartsLeft: 1, doubleOut: true))
        XCTAssertNil(CheckoutCalculator.suggestion(for: 121, dartsLeft: 2, doubleOut: true))
        XCTAssertNotNil(CheckoutCalculator.suggestion(for: 121, dartsLeft: 3, doubleOut: true))
    }

    func testEveryRouteIsLegalAndMinimal() {
        for doubleOut in [true, false] {
            let rules = X01Rules(startScore: 501, doubleOut: doubleOut)
            for score in 2...180 {
                for darts in 1...3 {
                    guard let route = CheckoutCalculator.suggestion(for: score, dartsLeft: darts, doubleOut: doubleOut) else { continue }
                    XCTAssertLessThanOrEqual(route.count, darts)
                    let result = X01.evaluate(route, from: score, rules: rules)
                    XCTAssertEqual(result.outcome, .checkout, "\(score) via \(route)")
                    XCTAssertEqual(result.endIndex, route.count - 1, "\(score) finishes on the last dart")
                    if route.count > 1 {
                        XCTAssertNil(CheckoutCalculator.suggestion(for: score, dartsLeft: route.count - 1, doubleOut: doubleOut),
                                     "\(score) has a shorter route than \(route)")
                    }
                }
            }
        }
    }

    func testStraightOutFinishesWithoutDouble() {
        XCTAssertEqual(CheckoutCalculator.suggestion(for: 20, dartsLeft: 1, doubleOut: false), [.single(20)])
        XCTAssertEqual(CheckoutCalculator.suggestion(for: 180, dartsLeft: 3, doubleOut: false), [.triple(20), .triple(20), .triple(20)])
    }

    func testMatchOffersRouteOnlyWhenReachable() {
        var match = X01Match(rules: X01Rules(startScore: 170, doubleOut: true), players: ["A"])
        XCTAssertEqual(match.checkoutSuggestion, [.triple(20), .triple(20), .bull])
        match.add(Dart(segment: .single(20)))   // 150 with two darts: no finish
        XCTAssertNil(match.checkoutSuggestion)
    }
}
