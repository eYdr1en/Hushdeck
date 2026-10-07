import Foundation

public enum OmniError: Error, Sendable, Equatable, LocalizedError {
    /// The opcode is on the DO NOT SEND list (protocol-notes §4). There is no override.
    case blockedOpcode(UInt8, reason: String)
    /// The opcode is not one of OmniKit's allowlisted commands.
    case notAllowlisted(UInt8)
    /// A packet did not have the shape OmniKit sends (report ID, length).
    case malformedPacket(String)
    /// A typed value is outside the range the protocol notes allow.
    case valueOutOfRange(feature: OmniFeature, value: String, allowed: String)
    /// Feature-report (EQ) writes are off. Turn on `experimentalEQWrites` first.
    case experimentalEQWritesDisabled
    case notConnected
    /// The hub enumerated less than 5 s ago; GG sends nothing during that window.
    case hubSettling
    case replyTimeout(query: String)
    case malformedReply(String)
    case transportFailure(operation: String, code: Int32)
    case transportStopped

    public var errorDescription: String? {
        switch self {
        case .blockedOpcode(let op, let reason):
            String(format: "Opcode 0x%02X is never sent (%@).", op, reason)
        case .notAllowlisted(let op):
            String(format: "Opcode 0x%02X is not an allowlisted Omni command.", op)
        case .malformedPacket(let why):
            "Refused a malformed packet: \(why)."
        case .valueOutOfRange(let feature, let value, let allowed):
            "\(feature.rawValue): \(value) is outside \(allowed)."
        case .experimentalEQWritesDisabled:
            "EQ writes are experimental and turned off."
        case .notConnected:
            "The Omni GameHub isn’t connected."
        case .hubSettling:
            "The Omni GameHub just connected; waiting before talking to it."
        case .replyTimeout(let query):
            "The GameHub didn’t answer the \(query) query."
        case .malformedReply(let why):
            "The GameHub sent a reply OmniKit can’t read: \(why)."
        case .transportFailure(let operation, let code):
            String(format: "%@ failed (IOReturn 0x%08X).", operation, UInt32(bitPattern: code))
        case .transportStopped:
            "The Omni transport is stopped."
        }
    }
}
