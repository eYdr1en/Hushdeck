import Foundation
import Observation
import ServiceManagement

/// User preferences, persisted in UserDefaults. Changes that affect how the CLI is
/// invoked call `onConnectionSettingsChange` so the model can rebuild its client.
@Observable
@MainActor
final class Preferences {
    private let defaults: UserDefaults

    var pollInterval: Double {
        didSet {
            defaults.set(pollInterval, forKey: Keys.pollInterval)
            onPollIntervalChange?()
        }
    }

    var reapplyOnConnect: Bool {
        didSet { defaults.set(reapplyOnConnect, forKey: Keys.reapply) }
    }

    var binaryPathOverride: String {
        didSet {
            defaults.set(binaryPathOverride, forKey: Keys.binaryPath)
            onConnectionSettingsChange?()
        }
    }

    var useTestDevice: Bool {
        didSet {
            defaults.set(useTestDevice, forKey: Keys.testDevice)
            onConnectionSettingsChange?()
        }
    }

    /// HeadsetControl test-device profile chosen in Settings (0 = normal).
    var testProfile: Int {
        didSet {
            defaults.set(testProfile, forKey: Keys.testProfile)
            if effectiveUseTestDevice { onConnectionSettingsChange?() }
        }
    }

    /// Show the battery percentage next to the menu bar icon.
    var showBatteryPercentage: Bool {
        didSet { defaults.set(showBatteryPercentage, forKey: Keys.showPercentage) }
    }

    var lowBatteryAlert: Bool {
        didSet {
            defaults.set(lowBatteryAlert, forKey: Keys.lowBatteryAlert)
            onAlertSettingsChange?()
        }
    }

    var lowBatteryThreshold: Int {
        didSet {
            // Assigning inside didSet doesn't re-trigger the observer.
            lowBatteryThreshold = BatteryAlertPolicy.clampedThreshold(lowBatteryThreshold)
            defaults.set(lowBatteryThreshold, forKey: Keys.lowBatteryThreshold)
            onAlertSettingsChange?()
        }
    }

    var fullyChargedAlert: Bool {
        didSet {
            defaults.set(fullyChargedAlert, forKey: Keys.fullyChargedAlert)
            onAlertSettingsChange?()
        }
    }

    /// The Omni GameHub charges a spare battery; alert when it reaches 100 %.
    var spareChargedAlert: Bool {
        didSet {
            defaults.set(spareChargedAlert, forKey: Keys.spareChargedAlert)
            onAlertSettingsChange?()
        }
    }

    /// Allows OmniKit's experimental EQ uploads (SET_FEATURE with an unconfirmed layout).
    var experimentalEQWrites: Bool {
        didSet {
            defaults.set(experimentalEQWrites, forKey: Keys.experimentalEQWrites)
            onEQWritesChange?()
        }
    }

    var alertSettings: BatteryAlertSettings {
        BatteryAlertSettings(lowBattery: lowBatteryAlert, threshold: lowBatteryThreshold, fullyCharged: fullyChargedAlert,
                             spareCharged: spareChargedAlert)
    }

    var wantsNotifications: Bool { lowBatteryAlert || fullyChargedAlert || spareChargedAlert }

    /// `HUSHDECK_TEST_DEVICE=1` forces the test device regardless of the toggle.
    let environmentForcesTestDevice: Bool
    /// `HUSHDECK_TEST_PROFILE=N` selects a test-device profile (2 = charging, 1 = errors, 10 = limited…).
    let environmentTestProfile: Int?

    var effectiveUseTestDevice: Bool { useTestDevice || environmentForcesTestDevice }

    /// Profile passed as `--test-device=N`; the environment variable wins over Settings.
    var effectiveTestProfile: Int? {
        if let environmentTestProfile { return environmentTestProfile }
        return testProfile == 0 ? nil : testProfile
    }

    @ObservationIgnored var onConnectionSettingsChange: (() -> Void)?
    @ObservationIgnored var onPollIntervalChange: (() -> Void)?
    @ObservationIgnored var onAlertSettingsChange: (() -> Void)?
    @ObservationIgnored var onEQWritesChange: (() -> Void)?

    static let pollIntervalChoices: [Double] = [15, 30, 60, 120, 300]
    static let lowBatteryThresholdChoices = [5, 10, 15, 20, 25, 30, 40, 50]
    /// HeadsetControl's `--test-device` profiles (see its headsetcontrol_test.hpp).
    static let testProfileChoices = [0, 1, 2, 3, 4, 5, 6, 7, 10]

    init(defaults: UserDefaults = .standard, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.pollInterval: 30.0,
            Keys.reapply: true,
            Keys.binaryPath: "",
            Keys.testDevice: false,
            Keys.testProfile: 0,
            Keys.showPercentage: true,
            Keys.lowBatteryAlert: false,
            Keys.lowBatteryThreshold: BatteryAlertPolicy.defaultThreshold,
            Keys.fullyChargedAlert: false,
            Keys.spareChargedAlert: false,
            Keys.experimentalEQWrites: true, // round-tripped on hardware (LiveHubEQTests)
        ])
        pollInterval = defaults.double(forKey: Keys.pollInterval)
        reapplyOnConnect = defaults.bool(forKey: Keys.reapply)
        binaryPathOverride = defaults.string(forKey: Keys.binaryPath) ?? ""
        useTestDevice = defaults.bool(forKey: Keys.testDevice)
        testProfile = defaults.integer(forKey: Keys.testProfile)
        showBatteryPercentage = defaults.bool(forKey: Keys.showPercentage)
        lowBatteryAlert = defaults.bool(forKey: Keys.lowBatteryAlert)
        lowBatteryThreshold = BatteryAlertPolicy.clampedThreshold(defaults.integer(forKey: Keys.lowBatteryThreshold))
        fullyChargedAlert = defaults.bool(forKey: Keys.fullyChargedAlert)
        spareChargedAlert = defaults.bool(forKey: Keys.spareChargedAlert)
        experimentalEQWrites = defaults.bool(forKey: Keys.experimentalEQWrites)
        let flag = environment["HUSHDECK_TEST_DEVICE"]?.lowercased()
        environmentForcesTestDevice = ["1", "true", "yes", "on"].contains(flag ?? "")
        environmentTestProfile = environment["HUSHDECK_TEST_PROFILE"].flatMap(Int.init)
    }

    private enum Keys {
        static let pollInterval = "pollInterval"
        static let reapply = "reapplyOnConnect"
        static let binaryPath = "headsetControlPath"
        static let testDevice = "useTestDevice"
        static let testProfile = "testDeviceProfile"
        static let showPercentage = "showBatteryPercentage"
        static let lowBatteryAlert = "lowBatteryAlert"
        static let lowBatteryThreshold = "lowBatteryThreshold"
        static let fullyChargedAlert = "fullyChargedAlert"
        static let spareChargedAlert = "spareChargedAlert"
        static let experimentalEQWrites = "omniExperimentalEQWrites"
    }
}

/// Wraps SMAppService. Only works when running from a real .app bundle.
@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
