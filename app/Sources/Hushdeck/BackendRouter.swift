import Foundation
import HeadsetControlKit
import OmniKit

/// Decides which backend drives which device. The Arctis Nova Pro Omni GameHub (1038:2290)
/// always goes through OmniKit; everything else keeps using the HeadsetControl CLI. When
/// HeadsetControl also lists the Omni (its driver only knows battery and sidetone), that entry is
/// dropped so two backends never open the same HID interface.
enum BackendRouter {
    enum Backend: Equatable {
        case omniKit
        case headsetControl
    }

    static let omniDeviceID = DeviceID(vendorID: UInt16(OmniUSB.vendorID), productID: UInt16(OmniUSB.gameHubProductID))

    static func backend(for device: DeviceInfo) -> Backend {
        isOmni(device) ? .omniKit : .headsetControl
    }

    static func isOmni(_ device: DeviceInfo) -> Bool {
        device.deviceID == omniDeviceID
    }

    /// The devices HeadsetControl should keep driving.
    static func headsetControlDevices(from devices: [DeviceInfo]) -> [DeviceInfo] {
        devices.filter { backend(for: $0) == .headsetControl }
    }

    /// Stable ID used for notifications and settings memory of the Omni, whichever backend
    /// reports it.
    static let omniNotificationID = omniDeviceID.filterArgument
}
