import Foundation
import Testing
@testable import HeadsetControlKit

/// Decodes JSON captured from `headsetcontrol --test-device[=N] -o json` (HeadsetControl 4.1.0-13, api 1.5).
@Suite("Decoding captured CLI output")
struct DecodingTests {
    @Test func fullTestDevice() throws {
        let output = try Fixture.output("status_full")
        #expect(output.apiVersion == "1.5")
        #expect(output.deviceCount == 1)
        #expect(output.actions.isEmpty)

        let device = try #require(output.devices.first)
        #expect(device.status == .success)
        #expect(device.name == "HeadsetControl Test device")
        #expect(device.deviceID == DeviceID(vendorID: 0xF00B, productID: 0xA00C))
        #expect(device.deviceID?.filterArgument == "f00b:a00c")
        #expect(device.isTestDevice)
        #expect(device.capabilities.count == 18)
        #expect(device.capabilityNames.count == 18)
        #expect(Set(device.capabilities) == Set(Capability.allKnown))
        #expect(device.unrecognisedCapabilities.isEmpty)
        #expect(device.noiseCancellingCapability == nil)
        #expect(device.displayName(for: .noiseFilter) == "microphone noise filter")

        let battery = try #require(device.battery)
        #expect(battery.status == .available)
        #expect(battery.percent == 42)
        #expect(battery.voltageMillivolts == 3650)
        #expect(battery.minutesToEmpty == 302)
        #expect(battery.minutesToFull == nil)
        #expect(device.connection == .connected(charging: false))

        #expect(device.equalizer == EqualizerInfo(bands: 10, baseline: 0, step: 0.5, min: -12, max: 12))
        #expect(device.equalizerPresetsCount == 4)
        #expect(device.chatmix == 64)
        #expect(device.sidetone?.level == 85)
        #expect(device.sidetone?.deviceLevel == 2)
        #expect(device.sidetone?.name == "Medium")
        #expect(device.errors.isEmpty)
        #expect(device.parametricEqualizer == nil)
    }

    @Test func presetsKeepDeviceOrder() throws {
        let device = try Fixture.device("status_full")
        // Not alphabetical: index order is what --equalizer-preset expects.
        #expect(device.presetNames == ["flat", "bass boost", "treble boost", "v-shape"])
        #expect(device.equalizerPresets[1].bands.prefix(3) == [6, 4, 2])
        #expect(device.equalizerPresets[3].bands == [4, 2, 0, -2, -2, -2, 0, 2, 4, 4])
    }

    @Test func charging() throws {
        let device = try Fixture.device("status_charging")
        #expect(device.battery?.status == .charging)
        #expect(device.battery?.percent == 50)
        #expect(device.battery?.minutesToFull == 60)
        #expect(device.connection == .connected(charging: true))
    }

    @Test func readErrorsArePartialNotFatal() throws {
        let device = try Fixture.device("status_errors")
        #expect(device.status == .partial)
        #expect(device.battery?.status == .unavailable)
        #expect(device.battery?.percent == nil)
        #expect(device.errors["battery"] == "HID communication error")
        #expect(device.errors["chatmix"] == "HID communication error")
        #expect(device.chatmix == nil)
        #expect(device.sidetone == nil)
        #expect(device.connection == .offline(reason: "HID communication error"))
    }

    @Test func headsetOffline() throws {
        let device = try Fixture.device("status_offline")
        #expect(device.connection == .offline(reason: "Device is offline or not responding"))
        #expect(!device.connection.isReachable)
    }

    @Test func timeout() throws {
        let device = try Fixture.device("status_timeout")
        #expect(device.errors["battery"] == "Operation timed out")
        #expect(!device.connection.isReachable)
    }

    @Test func limitedCapabilities() throws {
        let device = try Fixture.device("status_limited")
        #expect(device.capabilities == [.sidetone, .batteryStatus, .lights])
        #expect(!device.supports(.equalizer))
        #expect(device.equalizer == nil)
        #expect(device.presetNames.isEmpty)
        #expect(device.battery?.percent == 42)
        #expect(device.battery?.voltageMillivolts == nil)
    }

    @Test func noDevice() throws {
        let output = try Fixture.output("status_no_device")
        #expect(output.deviceCount == 0)
        #expect(output.devices.isEmpty)
    }

    @Test func singleAction() throws {
        let output = try Fixture.output("action_sidetone")
        #expect(output.actions == [ActionResult(capability: .sidetone, device: "HeadsetControl Test device", status: .success, value: 50)])
        // Setter runs skip info reads, so no battery block.
        #expect(output.devices.first?.battery == nil)
    }

    @Test func multipleActions() throws {
        let output = try Fixture.output("action_multiple")
        #expect(output.actions.map(\.capability) == [.sidetone, .lights, .inactiveTime])
        #expect(output.actions.allSatisfy { $0.succeeded })
        #expect(output.actions.map(\.value) == [50, 1, 30])
    }

    @Test func zeroValueIsOmitted() throws {
        let output = try Fixture.output("action_value_zero")
        let action = try #require(output.actions.first)
        #expect(action.capability == .lights)
        #expect(action.succeeded)
        #expect(action.value == nil)
    }

    @Test func partialActionFailure() throws {
        let output = try Fixture.output("action_partial_failure")
        #expect(output.actions.count == 2)
        let sidetone = try #require(output.actions.first { $0.capability == .sidetone })
        #expect(sidetone.status == .failure)
        #expect(sidetone.errorMessage == "HID communication error")
        #expect(output.actions.first { $0.capability == .lights }?.succeeded == true)
    }

    @Test func futureCapabilitiesDecodeGracefully() throws {
        let output = try Fixture.output("synthetic_future_anc")
        let device = try #require(output.devices.first)
        #expect(device.capabilities.contains(Capability(rawValue: "CAP_NOISE_CANCELLING")))
        #expect(device.noiseCancellingCapability == Capability(rawValue: "CAP_NOISE_CANCELLING"))
        #expect(device.unrecognisedCapabilities == [Capability(rawValue: "CAP_HOLOGRAPHIC_WIDENING")])
        #expect(device.displayName(for: Capability(rawValue: "CAP_HOLOGRAPHIC_WIDENING")) == "holographic widening")
        // Unknown battery status with a valid level still reads as connected.
        #expect(device.battery?.status == .other("BATTERY_SUPERCHARGED"))
        #expect(device.connection == .connected(charging: false))
        #expect(device.presetNames == ["zeta", "alpha", "mu"])
        let peq = try #require(device.parametricEqualizer)
        #expect(peq.bands == 10)
        #expect(peq.gain?.step == 0.1)
        #expect(peq.frequency?.max == 20000)
        #expect(peq.filterTypes.contains("brand-new-filter"))
    }

    @Test func orderedParserHandlesEscapesAndNesting() throws {
        let json = #"{"devices":[{"equalizer_presets":{"b \"q\"":[1],"aé":[2]}},{"x":null,"y":[true,false,-1.5e2]}]}"#
        let orders = try OrderedJSON.presetKeyOrder(in: Data(json.utf8))
        #expect(orders == [["b \"q\"", "aé"], []])
    }
}
