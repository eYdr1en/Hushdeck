import Testing
@testable import Hushdeck

@Suite("Battery alert policy")
struct BatteryAlertPolicyTests {
    let lowOnly = BatteryAlertSettings(lowBattery: true, threshold: 20, fullyCharged: false)
    let fullOnly = BatteryAlertSettings(lowBattery: false, threshold: 20, fullyCharged: true)
    let both = BatteryAlertSettings(lowBattery: true, threshold: 20, fullyCharged: true)

    func reading(_ level: Int?, charging: Bool = false, id: String = "1038:2244", name: String = "Arctis") -> BatteryReading {
        BatteryReading(deviceID: id, deviceName: name, level: level, charging: charging)
    }

    /// Runs a sequence of readings and returns the alerts each step produced.
    func run(_ steps: [BatteryReading], _ settings: BatteryAlertSettings, policy: inout BatteryAlertPolicy) -> [[BatteryAlert]] {
        steps.map { policy.evaluate([$0], settings: settings) }
    }

    // MARK: Low battery

    @Test func firesOnceWhenCrossingThreshold() {
        var policy = BatteryAlertPolicy()
        let alerts = run([reading(40), reading(25), reading(20), reading(18), reading(12)], lowOnly, policy: &policy)
        #expect(alerts == [[], [], [.low(deviceID: "1038:2244", deviceName: "Arctis", level: 20)], [], []])
    }

    @Test func firesImmediatelyWhenAlreadyLowAtFirstReading() {
        var policy = BatteryAlertPolicy()
        #expect(policy.evaluate([reading(8)], settings: lowOnly) == [.low(deviceID: "1038:2244", deviceName: "Arctis", level: 8)])
    }

    @Test func doesNotFireWhileCharging() {
        var policy = BatteryAlertPolicy()
        let alerts = run([reading(10, charging: true), reading(12, charging: true)], lowOnly, policy: &policy)
        #expect(alerts.allSatisfy { $0.isEmpty })
    }

    @Test func rearmsAfterCharging() {
        var policy = BatteryAlertPolicy()
        let alerts = run([
            reading(15),                  // alert
            reading(14),
            reading(30, charging: true),  // plugged in: new cycle
            reading(60),
            reading(19),                  // alert again
        ], lowOnly, policy: &policy)
        #expect(alerts.map(\.count) == [1, 0, 0, 0, 1])
    }

    @Test func smallWobbleAboveThresholdDoesNotRearm() {
        var policy = BatteryAlertPolicy()
        let alerts = run([reading(20), reading(21), reading(25), reading(20)], lowOnly, policy: &policy)
        #expect(alerts.map(\.count) == [1, 0, 0, 0])
    }

    @Test func swappedBatteryRearmsWithoutCharging() {
        // The Omni has hot-swappable batteries: the level jumps without a charging reading.
        var policy = BatteryAlertPolicy()
        let alerts = run([reading(10), reading(100), reading(90), reading(20)], lowOnly, policy: &policy)
        #expect(alerts.map(\.count) == [1, 0, 0, 1])
    }

    @Test func disabledAlertIsNotUsedUp() {
        var policy = BatteryAlertPolicy()
        #expect(policy.evaluate([reading(15)], settings: .off).isEmpty)
        #expect(policy.evaluate([reading(14)], settings: lowOnly).count == 1)
    }

    @Test func raisingThresholdAboveCurrentLevelFires() {
        // HeadsetControl's test device sits at 42%; a 50% threshold must alert.
        var policy = BatteryAlertPolicy()
        #expect(policy.evaluate([reading(42)], settings: lowOnly).isEmpty)
        var higher = lowOnly
        higher.threshold = 50
        #expect(policy.evaluate([reading(42)], settings: higher) == [.low(deviceID: "1038:2244", deviceName: "Arctis", level: 42)])
        #expect(policy.evaluate([reading(42)], settings: higher).isEmpty)
    }

    @Test func unknownLevelIsIgnored() {
        var policy = BatteryAlertPolicy()
        #expect(policy.evaluate([reading(nil)], settings: both).isEmpty)
        #expect(policy.evaluate([reading(15)], settings: both).count == 1)
    }

    @Test func devicesAreTrackedIndependently() {
        var policy = BatteryAlertPolicy()
        let a = reading(15, id: "a", name: "A")
        let b = reading(50, id: "b", name: "B")
        #expect(policy.evaluate([a, b], settings: lowOnly) == [.low(deviceID: "a", deviceName: "A", level: 15)])
        let bLow = reading(10, id: "b", name: "B")
        #expect(policy.evaluate([a, bLow], settings: lowOnly) == [.low(deviceID: "b", deviceName: "B", level: 10)])
    }

    @Test func thresholdIsClamped() {
        #expect(BatteryAlertPolicy.clampedThreshold(0) == 5)
        #expect(BatteryAlertPolicy.clampedThreshold(20) == 20)
        #expect(BatteryAlertPolicy.clampedThreshold(95) == 50)
        var policy = BatteryAlertPolicy()
        let silly = BatteryAlertSettings(lowBattery: true, threshold: 1_000, fullyCharged: false)
        #expect(policy.evaluate([reading(60)], settings: silly).isEmpty)
        #expect(policy.evaluate([reading(50)], settings: silly).count == 1)
    }

    // MARK: Fully charged

    @Test func fullyChargedFiresOnceAtHundredWhileCharging() {
        var policy = BatteryAlertPolicy()
        let alerts = run([
            reading(50, charging: true), reading(99, charging: true),
            reading(100, charging: true), reading(100, charging: true), reading(100),
        ], fullOnly, policy: &policy)
        #expect(alerts == [[], [], [.fullyCharged(deviceID: "1038:2244", deviceName: "Arctis")], [], []])
    }

    @Test func fullyChargedFiresWhenChargingEndsAtHundred() {
        var policy = BatteryAlertPolicy()
        let alerts = run([reading(90, charging: true), reading(100)], fullOnly, policy: &policy)
        #expect(alerts.map(\.count) == [0, 1])
    }

    @Test func unpluggedBeforeFullDoesNotFire() {
        var policy = BatteryAlertPolicy()
        let alerts = run([reading(70, charging: true), reading(80), reading(100)], fullOnly, policy: &policy)
        #expect(alerts.allSatisfy { $0.isEmpty })
    }

    @Test func alreadyFullWithoutChargingDoesNotFire() {
        var policy = BatteryAlertPolicy()
        #expect(policy.evaluate([reading(100), reading(100, charging: true)], settings: fullOnly).isEmpty)
    }

    @Test func chargingWithUnknownLevelArmsFullAlert() {
        var policy = BatteryAlertPolicy()
        let alerts = run([reading(nil, charging: true), reading(100, charging: true)], fullOnly, policy: &policy)
        #expect(alerts.map(\.count) == [0, 1])
    }

    @Test func fullyChargedDisabledStaysQuiet() {
        var policy = BatteryAlertPolicy()
        let alerts = run([reading(50, charging: true), reading(100, charging: true)], lowOnly, policy: &policy)
        #expect(alerts.allSatisfy { $0.isEmpty })
    }

    @Test func fullCycleProducesBothAlerts() {
        var policy = BatteryAlertPolicy()
        let alerts = run([
            reading(30), reading(20),                               // low
            reading(25, charging: true), reading(100, charging: true), // full
            reading(90), reading(19),                               // low again
        ], both, policy: &policy)
        #expect(alerts.map(\.count) == [0, 1, 0, 1, 0, 1])
    }
}
