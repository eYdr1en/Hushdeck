import Foundation

/// The DO NOT SEND list and the write allowlists (protocol-notes §4, mirrored from `tools/probe.py`).
///
/// This is the lowest layer of OmniKit. Every byte buffer that can reach a transport is an
/// `OmniOutputReport` or an `OmniFeatureReport`, and both types can only be created through
/// `OmniSafety.validateOutput` / `validateFeatureWrite`. The IOKit and simulated transports run the
/// same checks again immediately before the bytes leave the process. There is no override.
public enum OmniSafety {
    /// Opcodes that are confirmed dangerous.
    public static let blockedOpcodes: [UInt8: String] = [
        0x01: "reset MCU / reboot into bootloader",
        0x02: "firmware-update (Fizz) sequence",
        0xFD: "restore factory defaults",
    ]
    /// Conservative ranges: unknown, and not worth the risk.
    public static let blockedRanges: [ClosedRange<UInt8>] = [0x00...0x08, 0xF0...0xFF]

    /// Settings writes (§3.4) that OmniKit may send as 64-byte output reports.
    public static let settingOpcodes: Set<UInt8> = [
        0x38, 0x37, 0x3C, 0xBF, 0xBD, 0xB8, 0xB9, 0xC1, 0x27, 0x43, 0x47,
        0x85, 0x83, 0x88, 0x89, 0x8A, 0xB2, 0xB3,
    ]
    /// Save-to-flash.
    public static let saveOpcode: UInt8 = 0x09
    /// Read queries (§3.1, §3.3, §3.5, §3.6, §3.7).
    public static let queryOpcodes: Set<UInt8> = [0xB0, 0x10, 0x12, 0x80, 0x20, 0x1A, 0x1E, 0x1C, 0x18]
    /// Every opcode that may appear in an output report.
    public static var outputOpcodes: Set<UInt8> { settingOpcodes.union(queryOpcodes).union([saveOpcode]) }
    /// The only feature-report writes: 2.4 GHz, mic and Bluetooth EQ uploads (§3.7).
    public static let featureWriteOpcodes: Set<UInt8> = [0x1B, 0x1D, 0x1F]

    /// Why an opcode is on the DO NOT SEND list, or `nil` if it isn't.
    public static func blockReason(for opcode: UInt8) -> String? {
        if let reason = blockedOpcodes[opcode] { return reason }
        for range in blockedRanges where range.contains(opcode) {
            return String(format: "in the blocked range 0x%02X-0x%02X", range.lowerBound, range.upperBound)
        }
        return nil
    }

    public static func isBlocked(_ opcode: UInt8) -> Bool { blockReason(for: opcode) != nil }

    /// Checks a complete 64-byte output report. Used by `OmniOutputReport` and again by transports.
    public static func validateOutput(_ bytes: [UInt8]) throws {
        guard bytes.count == OmniUSB.outputReportLength else {
            throw OmniError.malformedPacket("output report is \(bytes.count) bytes, expected \(OmniUSB.outputReportLength)")
        }
        guard bytes[0] == OmniUSB.reportID else {
            throw OmniError.malformedPacket(String(format: "report ID 0x%02X (only 0x01 is allowed)", bytes[0]))
        }
        let opcode = bytes[1]
        if let reason = blockReason(for: opcode) { throw OmniError.blockedOpcode(opcode, reason: reason) }
        guard outputOpcodes.contains(opcode) else { throw OmniError.notAllowlisted(opcode) }
    }

    /// Checks a complete 1036-byte feature-report write. The experimental flag is checked by
    /// `OmniFeatureReport`'s initialiser; transports call this for the byte-level checks.
    public static func validateFeatureWrite(_ bytes: [UInt8]) throws {
        guard bytes.count == OmniUSB.featureReportLength else {
            throw OmniError.malformedPacket("feature report is \(bytes.count) bytes, expected \(OmniUSB.featureReportLength)")
        }
        guard bytes[0] == OmniUSB.reportID else {
            throw OmniError.malformedPacket(String(format: "report ID 0x%02X (only 0x01 is allowed)", bytes[0]))
        }
        let opcode = bytes[1]
        if let reason = blockReason(for: opcode) { throw OmniError.blockedOpcode(opcode, reason: reason) }
        guard featureWriteOpcodes.contains(opcode) else { throw OmniError.notAllowlisted(opcode) }
    }
}

/// Write permissions that are not about the DO NOT SEND list.
public struct OmniWritePolicy: Sendable, Equatable, Codable {
    /// Allows EQ uploads (SET_FEATURE 0x1B / 0x1D / 0x1F). The layout is confirmed on hardware
    /// (protocol-notes §3.7); the policy still defaults to off so callers opt in explicitly.
    public var experimentalEQWrites: Bool

    public init(experimentalEQWrites: Bool = false) {
        self.experimentalEQWrites = experimentalEQWrites
    }
}

/// A 64-byte output report that passed the safety checks. The initialiser is internal: outside
/// OmniKit, reports only come from `OmniSetting`, `OmniQuery` and `saveToFlash`.
public struct OmniOutputReport: Sendable, Hashable, CustomStringConvertible {
    public let bytes: [UInt8]

    init(opcode: UInt8, arguments: [UInt8] = []) throws {
        guard arguments.count <= OmniUSB.outputReportLength - 2 else {
            throw OmniError.malformedPacket("too many argument bytes (\(arguments.count))")
        }
        var bytes = [OmniUSB.reportID, opcode] + arguments
        bytes += [UInt8](repeating: 0, count: OmniUSB.outputReportLength - bytes.count)
        try OmniSafety.validateOutput(bytes)
        self.bytes = bytes
    }

    public var opcode: UInt8 { bytes[1] }

    /// Save-to-flash (`01 09`).
    public static func saveToFlash() -> OmniOutputReport {
        try! OmniOutputReport(opcode: OmniSafety.saveOpcode)
    }

    public var description: String { OmniHex.trimmed(bytes) }
}

/// A 1036-byte feature report write (EQ upload). Only constructible while
/// `OmniWritePolicy.experimentalEQWrites` is on.
public struct OmniFeatureReport: Sendable, Hashable, CustomStringConvertible {
    public let bytes: [UInt8]

    init(opcode: UInt8, payload: [UInt8], policy: OmniWritePolicy) throws {
        guard policy.experimentalEQWrites else { throw OmniError.experimentalEQWritesDisabled }
        guard payload.count <= OmniUSB.featureReportLength - 2 else {
            throw OmniError.malformedPacket("feature payload too long (\(payload.count))")
        }
        var bytes = [OmniUSB.reportID, opcode] + payload
        bytes += [UInt8](repeating: 0, count: OmniUSB.featureReportLength - bytes.count)
        try OmniSafety.validateFeatureWrite(bytes)
        self.bytes = bytes
    }

    public var opcode: UInt8 { bytes[1] }
    public var description: String { OmniHex.trimmed(bytes) }
}

public enum OmniHex {
    /// "01 38 01 05 (+60 zero bytes, total 64)", like probe.py's hexdump.
    public static func trimmed(_ bytes: [UInt8]) -> String {
        var end = bytes.count
        while end > 2, bytes[end - 1] == 0 { end -= 1 }
        let shown = bytes[..<end].map { String(format: "%02X", $0) }.joined(separator: " ")
        return end < bytes.count ? "\(shown) (+\(bytes.count - end) zero bytes, total \(bytes.count))" : shown
    }

    public static func string(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }

    public static func bytes(_ hex: String) -> [UInt8]? {
        let clean = hex.filter { !$0.isWhitespace }
        guard clean.count.isMultiple(of: 2) else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(clean.count / 2)
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }
}
