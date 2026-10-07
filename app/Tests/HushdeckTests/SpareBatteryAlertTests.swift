import Testing
@testable import Hushdeck

@Suite("Spare battery alerts")
struct SpareBatteryAlertTests {
    let spareOnly = BatteryAlertSettings(lowBattery: false, threshold: 20, fullyCharged: false, spareCharged: true)

    func reading(_ level: Int?, spare: Int?, charging: Bool = false) -> BatteryReading {
        BatteryReading(deviceID: "1038:2290", deviceName: "Omni", level: level, charging: charging, spareLevel: spare)
    }

    @Test func firesOnceWhenTheSpareReachesFull() {
        var policy = BatteryAlertPolicy()
        let steps = [reading(80, spare: 90), reading(79, spare: 99), reading(79, spare: 100), reading(78, spare: 100)]
        let alerts = steps.map { policy.evaluate([$0], settings: spareOnly) }
        #expect(alerts == [[], [], [.spareCharged(deviceID: "1038:2290", deviceName: "Omni")], []])
    }

    @Test func aSpareThatIsAlreadyFullDoesNotFire() {
        var policy = BatteryAlertPolicy()
        #expect(policy.evaluate([reading(80, spare: 100), reading(80, spare: 100)], settings: spareOnly).isEmpty)
    }

    @Test func hotSwapRearmsTheAlert() {
        var policy = BatteryAlertPolicy()
        let steps = [reading(10, spare: 100), reading(10, spare: 95), reading(95, spare: 12), reading(94, spare: 60), reading(93, spare: 100)]
        let counts = steps.map { policy.evaluate([$0], settings: spareOnly).count }
        #expect(counts == [0, 0, 0, 0, 1])
    }

    @Test func disabledAlertStaysArmed() {
        var policy = BatteryAlertPolicy()
        #expect(policy.evaluate([reading(50, spare: 40)], settings: .off).isEmpty)
        #expect(policy.evaluate([reading(50, spare: 100)], settings: .off).isEmpty)
        // Turned on later: the spare is full and the user hasn't been told yet.
        #expect(policy.evaluate([reading(50, spare: 100)], settings: spareOnly).count == 1)
        #expect(policy.evaluate([reading(50, spare: 100)], settings: spareOnly).isEmpty)
    }

    @Test func devicesWithoutASpareAreUnaffected() {
        var policy = BatteryAlertPolicy()
        let plain = BatteryReading(deviceID: "1038:12e0", deviceName: "Nova", level: 50, charging: false)
        #expect(policy.evaluate([plain, reading(50, spare: 30)], settings: spareOnly).isEmpty)
        #expect(policy.evaluate([plain, reading(50, spare: 100)], settings: spareOnly) == [.spareCharged(deviceID: "1038:2290", deviceName: "Omni")])
    }

    @Test func spareAlertDoesNotDisturbTheHeadsetRules() {
        var policy = BatteryAlertPolicy()
        let all = BatteryAlertSettings(lowBattery: true, threshold: 20, fullyCharged: true, spareCharged: true)
        let alerts = policy.evaluate([reading(15, spare: 100)], settings: all)
        #expect(alerts == [.low(deviceID: "1038:2290", deviceName: "Omni", level: 15)])
        let later = policy.evaluate([reading(90, spare: 100, charging: true), reading(100, spare: 30), reading(100, spare: 100)], settings: all)
        #expect(later == [.fullyCharged(deviceID: "1038:2290", deviceName: "Omni"), .spareCharged(deviceID: "1038:2290", deviceName: "Omni")])
    }

    @Test @MainActor func ggThresholdIsOffered() {
        #expect(BatteryAlertPolicy.ggThreshold == 5)
        #expect(Preferences.lowBatteryThresholdChoices.contains(BatteryAlertPolicy.ggThreshold))
    }
}
