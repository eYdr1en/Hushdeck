import Foundation

/// USB identity and framing of the Arctis Nova Pro Omni GameHub.
/// Source: `protocol/protocol-notes.md` §1 and §2.
public enum OmniUSB {
    public static let vendorID = 0x1038
    /// The GameHub in normal mode. The only product OmniKit ever opens.
    public static let gameHubProductID = 0x2290

    /// Products OmniKit refuses outright. They are never matched, opened or written to.
    public static let refusedProductIDs: [Int: String] = [
        0x2291: "Omni GameHub in bootloader mode",
        0x2296: "Omni headset on its own USB cable (firmware functions only)",
        0x2297: "Omni headset in bootloader mode",
    ]

    /// HID interface that carries both vendor collections.
    public static let hidInterface = 3
    /// Collection used for commands and query replies.
    public static let commandUsagePage = 0xFFC0
    /// Collection on which the hub sends unsolicited change events.
    public static let eventUsagePage = 0xFF00
    public static let vendorUsage = 0x0001

    /// Every GameHub command uses report ID 0x01.
    public static let reportID: UInt8 = 0x01
    /// Short commands and query replies: 64 bytes including the report ID.
    public static let outputReportLength = 64
    /// Long data (full audio settings, EQ): 1036 bytes including the report ID.
    public static let featureReportLength = 1036

    public static func isRefused(productID: Int) -> Bool {
        refusedProductIDs[productID] != nil
    }

    /// `true` only for the one product OmniKit talks to.
    public static func isSupported(vendorID: Int, productID: Int) -> Bool {
        vendorID == Self.vendorID && productID == gameHubProductID && !isRefused(productID: productID)
    }
}

/// Pacing GG uses on this device (protocol-notes §2).
public enum OmniTiming {
    /// Minimum gap between two transfers. Enforced by `OmniChannel`; cannot be lowered.
    public static let minimumCommandSpacing: Duration = .milliseconds(50)
    /// GG waits this long after the last setting before sending save-to-flash.
    public static let saveDelay: Duration = .milliseconds(500)
    /// GG waits this long after the hub enumerates before sending anything.
    public static let startupSettle: Duration = .seconds(5)
    /// Default time to wait for a 64-byte query reply.
    public static let replyTimeout: Duration = .seconds(1)
}
