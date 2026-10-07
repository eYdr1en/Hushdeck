import Foundation

/// Whether the headset itself (as opposed to its dongle/dock) is reachable.
public enum HeadsetConnection: Sendable, Equatable {
    case connected(charging: Bool)
    /// The dongle/dock is present but the headset is off, asleep or out of range.
    case offline(reason: String?)
    /// The device has no battery capability, so presence is all we know.
    case unknown

    public var isReachable: Bool {
        if case .offline = self { return false }
        return true
    }
}

extension DeviceInfo {
    public var connection: HeadsetConnection {
        guard supports(.batteryStatus) else { return .unknown }
        guard let battery else { return .offline(reason: errors["battery"]) }
        switch battery.status {
        case .available: return .connected(charging: false)
        case .charging: return .connected(charging: true)
        case .unavailable, .error, .timeout:
            return .offline(reason: errors["battery"])
        case .other:
            // A status this build doesn't know; trust a valid level.
            return battery.percent != nil ? .connected(charging: false) : .offline(reason: errors["battery"])
        }
    }
}
