import XCTest

final class ThresholdAlertGateTests: XCTestCase {
    func testCyclesThresholdsAndIndependentMetrics() {
        var gate = ThresholdAlertGate()
        let cycle = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(gate.shouldNotify(key: "a", value: 99.9, threshold: 100, cycle: cycle))
        XCTAssertTrue(gate.shouldNotify(key: "a", value: 100, threshold: 100, cycle: cycle))
        XCTAssertFalse(gate.shouldNotify(key: "a", value: 120, threshold: 100, cycle: cycle))
        XCTAssertTrue(gate.shouldNotify(key: "b", value: 100, threshold: 100, cycle: cycle))
        XCTAssertFalse(gate.shouldNotify(key: "a", value: 20, threshold: 100, cycle: cycle))
        XCTAssertFalse(gate.shouldNotify(key: "a", value: 100, threshold: 100, cycle: cycle))
        XCTAssertTrue(gate.shouldNotify(key: "a", value: 100, threshold: 100, cycle: cycle.addingTimeInterval(100)))
        XCTAssertTrue(gate.shouldNotify(key: "a", value: 80, threshold: 80, cycle: cycle.addingTimeInterval(100)))
    }

    func testMissingResetRequiresRecoveryAndFailedDeliveryCanRetry() {
        var gate = ThresholdAlertGate()
        XCTAssertTrue(gate.shouldNotify(key: "a", value: 80, threshold: 80, cycle: nil))
        XCTAssertFalse(gate.shouldNotify(key: "a", value: 90, threshold: 80, cycle: nil))
        XCTAssertFalse(gate.shouldNotify(key: "a", value: .nan, threshold: 80, cycle: nil))
        XCTAssertFalse(gate.shouldNotify(key: "a", value: .infinity, threshold: 80, cycle: nil))
        XCTAssertFalse(gate.shouldNotify(key: "a", value: 79, threshold: 80, cycle: nil))
        XCTAssertTrue(gate.shouldNotify(key: "a", value: 80, threshold: 80, cycle: nil))
        gate.retry(key: "a")
        XCTAssertTrue(gate.shouldNotify(key: "a", value: 80, threshold: 80, cycle: nil))
    }
}
