import Foundation
import Testing
@testable import OmniKit

@Suite("Feature catalog and confidence")
struct FeatureCatalogTests {
    @Test func everyFeatureHasAConfidenceAndAWireReference() {
        for feature in OmniFeature.allCases {
            #expect(feature.readConfidence != nil || feature.writeConfidence != nil, "\(feature)")
            #expect(!feature.wireReference.isEmpty)
        }
    }

    @Test func hardwareConfirmedMatchesTheLiveHubTests() {
        // Settings round-tripped on a real GameHub (LiveHubWriteTests); readouts that still need
        // checking against the hub itself stay documented-only; EQ writes and save stay below confirmed.
        let notConfirmed = Set(OmniFeature.allCases.filter { $0.confidence != .hardwareConfirmed })
        #expect(notConfirmed == [.spareBattery, .headsetLink, .bluetoothStatus, .chatMixDial, .audioInput,
                                 .colourVariant, .wirelessMode, .saveToDevice])
        #expect(OmniFeature.sidetone.confidence == .hardwareConfirmed)
        #expect(OmniFeature.wirelessEQ.readConfidence == .hardwareConfirmed)
        #expect(OmniFeature.wirelessEQ.confidence == .hardwareConfirmed)
    }

    @Test func eqWritesAreConfirmedAndStillGated() {
        for feature in [OmniFeature.wirelessEQ, .bluetoothEQ, .micEQ] {
            #expect(feature.requiresExperimentalEQWrites)
            #expect(feature.writeConfidence == .hardwareConfirmed)
        }
        #expect(OmniFeature.allCases.filter(\.requiresExperimentalEQWrites).count == 3)
    }

    @Test func everyWritableNonEQFeatureHasATypedSetting() {
        let settingFeatures: Set<OmniFeature> = [
            .sidetone, .micVolume, .micNoiseReduction, .mutedMicLEDBrightness, .ancMode, .ancLevel, .transparencyLevel, .autoOff,
            .volumeLimiter, .outputMode, .streamMix, .oledBrightness, .screensaverTimeout, .screensaverMode, .homeScreenView,
            .homeScreenOption, .bluetoothPowerOnDefault, .bluetoothCallBehaviour,
        ]
        let writable = Set(OmniFeature.allCases.filter { $0.isWritable && !$0.requiresExperimentalEQWrites && $0 != .saveToDevice })
        #expect(writable == settingFeatures)
    }

    @Test func confidenceOrdering() {
        #expect(OmniConfidence.inferred < .documented)
        #expect(OmniConfidence.documented < .hardwareConfirmed)
    }

    @Test func timeoutTable() {
        #expect(OmniTimeout.allCases.map(\.minutes) == [0, 1, 5, 10, 15, 30, 60])
        #expect(OmniTimeout(minutes: 45) == nil)
        #expect(OmniTimeout(minutes: 30)?.rawValue == 5)
    }
}
