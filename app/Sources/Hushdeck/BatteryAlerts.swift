import Foundation

/// One battery observation for a reachable headset.
struct BatteryReading: Sendable, Equatable {
    var deviceID: String
    var deviceName: String
    /// 0...100, or nil when the headset didn't report a level.
    var level: Int?
    var charging: Bool
    /// Spare battery in a charging dock (the Omni GameHub), 0...100, or nil when there is none.
    var spareLevel: Int? = nil
}

struct BatteryAlertSettings: Sendable, Equatable {
    var lowBattery: Bool
    /// Alert when the level is at or below this percentage.
    var threshold: Int
    var fullyCharged: Bool
    /// Alert when a spare battery in the dock reaches 100 %.
    var spareCharged: Bool

    init(lowBattery: Bool, threshold: Int, fullyCharged: Bool, spareCharged: Bool = false) {
        self.lowBattery = lowBattery
        self.threshold = threshold
        self.fullyCharged = fullyCharged
        self.spareCharged = spareCharged
    }

    static let off = BatteryAlertSettings(lowBattery: false, threshold: BatteryAlertPolicy.defaultThreshold, fullyCharged: false)
}

enum BatteryAlert: Sendable, Equatable {
    case low(deviceID: String, deviceName: String, level: Int)
    case fullyCharged(deviceID: String, deviceName: String)
    case spareCharged(deviceID: String, deviceName: String)

    var deviceID: String {
        switch self {
        case .low(let id, _, _), .fullyCharged(let id, _), .spareCharged(let id, _): id
        }
    }
}

/// Decides when to post battery notifications. Pure state machine: feed it every
/// reading, post whatever it returns.
///
/// - Low battery fires once per discharge cycle: at the first reading at or below
///   the threshold while not charging. It re-arms when the headset is seen
///   charging, or when the level climbs clearly above the threshold (a swapped or
///   externally charged battery). Small wobbles around the threshold don't re-arm.
/// - "Fully charged" arms while the headset charges below 100% and fires at the
///   first reading of 100%, charging or not. Unplugging before full disarms it.
/// - "Spare charged" arms when the dock's spare battery is seen below 100% and
///   fires at the first reading of 100%. A hot swap puts the drained battery in the
///   dock, which arms it again.
/// - A disabled alert never fires and never consumes its opportunity, so turning
///   it on later still alerts for the current cycle.
struct BatteryAlertPolicy: Sendable, Equatable {
    static let defaultThreshold = 20
    /// GG's own low-battery flag is 0 < level ≤ 5 %.
    static let ggThreshold = 5
    static let thresholdRange = 5...50
    /// How far above the threshold the level must rise (without charging) to re-arm.
    static let rearmMargin = 5

    private var lowAlerted: Set<String> = []
    private var chargingTowardsFull: Set<String> = []
    private var spareBelowFull: Set<String> = []

    static func clampedThreshold(_ value: Int) -> Int {
        min(max(value, thresholdRange.lowerBound), thresholdRange.upperBound)
    }

    mutating func evaluate(_ readings: [BatteryReading], settings: BatteryAlertSettings) -> [BatteryAlert] {
        let threshold = Self.clampedThreshold(settings.threshold)
        var alerts: [BatteryAlert] = []
        for reading in readings {
            let id = reading.deviceID

            // Spare battery in the dock
            if let spare = reading.spareLevel {
                if spare < 100 {
                    spareBelowFull.insert(id)
                } else if spareBelowFull.contains(id), settings.spareCharged {
                    spareBelowFull.remove(id)
                    alerts.append(.spareCharged(deviceID: id, deviceName: reading.deviceName))
                }
            }

            // Fully charged
            if reading.charging, (reading.level ?? 0) < 100 {
                chargingTowardsFull.insert(id)
            } else if chargingTowardsFull.contains(id), let level = reading.level {
                if level >= 100 {
                    chargingTowardsFull.remove(id)
                    if settings.fullyCharged {
                        alerts.append(.fullyCharged(deviceID: id, deviceName: reading.deviceName))
                    }
                } else if !reading.charging {
                    chargingTowardsFull.remove(id) // unplugged before full
                }
            }

            // Low battery
            if reading.charging {
                lowAlerted.remove(id)
                continue
            }
            guard let level = reading.level else { continue }
            if level > threshold + Self.rearmMargin {
                lowAlerted.remove(id)
            } else if level <= threshold, settings.lowBattery, !lowAlerted.contains(id) {
                lowAlerted.insert(id)
                alerts.append(.low(deviceID: id, deviceName: reading.deviceName, level: level))
            }
        }
        return alerts
    }
}
