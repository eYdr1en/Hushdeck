import Foundation
import HeadsetControlKit
import OmniKit
import Testing
@testable import Hushdeck

@Suite("Backend routing")
struct BackendRoutingTests {
    static func device(name: String, vendor: String, product: String) throws -> DeviceInfo {
        let json = """
        {"status":"success","device":"\(name)","vendor":"SteelSeries","product":"\(name)",
         "id_vendor":"\(vendor)","id_product":"\(product)","capabilities":["CAP_BATTERY_STATUS","CAP_SIDETONE"],
         "capabilities_str":["battery status","sidetone"],"battery":{"status":"BATTERY_AVAILABLE","level":50}}
        """
        return try JSONDecoder().decode(DeviceInfo.self, from: Data(json.utf8))
    }

    @Test func omniGoesToOmniKitAndEverythingElseToHeadsetControl() throws {
        let omni = try Self.device(name: "Arctis Nova Pro Omni", vendor: "0x1038", product: "0x2290")
        let nova = try Self.device(name: "Arctis Nova Pro Wireless", vendor: "0x1038", product: "0x12e0")
        let test = try Self.device(name: "Test device", vendor: "0xf00b", product: "0xa00c")
        #expect(BackendRouter.backend(for: omni) == .omniKit)
        #expect(BackendRouter.backend(for: nova) == .headsetControl)
        #expect(BackendRouter.backend(for: test) == .headsetControl)
        #expect(BackendRouter.headsetControlDevices(from: [omni, nova, test]).map(\.name) == [nova.name, test.name])
        #expect(BackendRouter.omniNotificationID == "1038:2290")
    }

    @Test func refusedOmniProductsNeverRouteToOmniKit() throws {
        // The headset on its own cable and the bootloader IDs stay with HeadsetControl (which
        // doesn't know them either); OmniKit only ever opens 0x2290.
        for product in ["0x2291", "0x2296", "0x2297"] {
            let device = try Self.device(name: "Omni?", vendor: "0x1038", product: product)
            #expect(BackendRouter.backend(for: device) == .headsetControl, Comment(rawValue: product))
        }
    }

    @Test func omniBatteryReadingFollowsTheHubState() throws {
        var state = OmniState()
        #expect(AppModel.omniBatteryReading(state) == nil, "not connected")

        state.connection = .settling(OmniHubInfo(isSimulated: true))
        state.readouts.headsetBattery = 40
        #expect(AppModel.omniBatteryReading(state) == nil, "settling")

        state.connection = .connected(OmniHubInfo(isSimulated: true))
        state.readouts.headsetLink = .connected
        state.readouts.charging = .charging
        state.readouts.spareBattery = 77
        let reading = try #require(AppModel.omniBatteryReading(state))
        #expect(reading == BatteryReading(deviceID: "1038:2290", deviceName: "Arctis Nova Pro Omni", level: 40, charging: true, spareLevel: 77))

        // Headset off: the level isn't trusted, but the spare in the hub still is.
        state.readouts.headsetLink = .disconnected
        let offline = try #require(AppModel.omniBatteryReading(state))
        #expect(offline.level == nil)
        #expect(offline.charging == false)
        #expect(offline.spareLevel == 77)

        state.readouts.spareBattery = nil
        #expect(AppModel.omniBatteryReading(state) == nil, "nothing to report")
    }

    @Test @MainActor func statusIconPrefersTheOmniWhenAHubIsPresent() async throws {
        let sim = SimulatedOmniTransport()
        let omni = OmniController(transport: sim, configuration: testOmniConfiguration(), defaults: scratchDefaults())
        let model = AppModel(preferences: Preferences(defaults: scratchDefaults(), environment: [:]), notifier: NullNotifier(), omni: omni)
        #expect(model.statusIconState == .inactive)
        omni.start()
        try await waitUntil("ready") { omni.isReady && omni.state.lastRefresh != nil }
        #expect(model.statusIconState == .active(level: 87, charging: false))
        sim.simulateHeadsetPower(on: false)
        try await waitUntil("headset off") { !omni.headsetOnline }
        #expect(model.statusIconState == .inactive)
        #expect(model.statusAccessibilityLabel.contains("off"))
        omni.stop()
    }
}
