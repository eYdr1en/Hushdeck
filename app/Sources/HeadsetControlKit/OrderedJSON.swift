import Foundation

/// A tiny order-preserving JSON reader. `JSONDecoder` and `JSONSerialization` both
/// discard object key order; this exists solely to recover the order of
/// `devices[i].equalizer_presets`, whose position is the preset index.
enum OrderedJSON {
    indirect enum Value {
        case object([(String, Value)])
        case array([Value])
        case string(String)
        case number(Double)
        case bool(Bool)
        case null

        subscript(key: String) -> Value? {
            if case .object(let pairs) = self { return pairs.first { $0.0 == key }?.1 }
            return nil
        }
    }

    struct ParseError: Error {
        var offset: Int
        var reason: String
    }

    static func parse(_ data: Data) throws -> Value {
        var parser = Parser(bytes: Array(data))
        parser.skipWhitespace()
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else {
            throw ParseError(offset: parser.index, reason: "trailing characters")
        }
        return value
    }

    /// For each device (in order), the preset names in the order they appear.
    static func presetKeyOrder(in data: Data) throws -> [[String]] {
        guard case .array(let devices)? = try parse(data)["devices"] else { return [] }
        return devices.map { device in
            if case .object(let pairs)? = device["equalizer_presets"] { return pairs.map(\.0) }
            return []
        }
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[index]) { index += 1 }
        }

        mutating func expect(_ byte: UInt8) throws {
            guard index < bytes.count, bytes[index] == byte else {
                throw ParseError(offset: index, reason: "expected \(Character(UnicodeScalar(byte)))")
            }
            index += 1
        }

        mutating func parseValue() throws -> Value {
            guard index < bytes.count else { throw ParseError(offset: index, reason: "unexpected end") }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try parseObject()
            case UInt8(ascii: "["): return try parseArray()
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default: return try parseNumber()
            }
        }

        mutating func literal(_ word: String) throws {
            for byte in word.utf8 { try expect(byte) }
        }

        mutating func parseObject() throws -> Value {
            try expect(UInt8(ascii: "{"))
            var pairs: [(String, Value)] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(pairs) }
            while true {
                skipWhitespace()
                let key = try parseString()
                skipWhitespace()
                try expect(UInt8(ascii: ":"))
                skipWhitespace()
                pairs.append((key, try parseValue()))
                skipWhitespace()
                guard index < bytes.count else { throw ParseError(offset: index, reason: "unterminated object") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                try expect(UInt8(ascii: "}"))
                return .object(pairs)
            }
        }

        mutating func parseArray() throws -> Value {
            try expect(UInt8(ascii: "["))
            var items: [Value] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
            while true {
                skipWhitespace()
                items.append(try parseValue())
                skipWhitespace()
                guard index < bytes.count else { throw ParseError(offset: index, reason: "unterminated array") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                try expect(UInt8(ascii: "]"))
                return .array(items)
            }
        }

        mutating func parseString() throws -> String {
            try expect(UInt8(ascii: "\""))
            var scalars: [UInt8] = []
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                switch byte {
                case UInt8(ascii: "\""):
                    return String(decoding: scalars, as: UTF8.self)
                case UInt8(ascii: "\\"):
                    guard index < bytes.count else { break }
                    let escaped = bytes[index]
                    index += 1
                    switch escaped {
                    case UInt8(ascii: "n"): scalars.append(0x0A)
                    case UInt8(ascii: "t"): scalars.append(0x09)
                    case UInt8(ascii: "r"): scalars.append(0x0D)
                    case UInt8(ascii: "b"): scalars.append(0x08)
                    case UInt8(ascii: "f"): scalars.append(0x0C)
                    case UInt8(ascii: "u"):
                        guard index + 4 <= bytes.count,
                              let code = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16)
                        else { throw ParseError(offset: index, reason: "bad unicode escape") }
                        index += 4
                        let scalar = UnicodeScalar(code) ?? "?"
                        scalars.append(contentsOf: Array(String(Character(scalar)).utf8))
                    default: scalars.append(escaped)
                    }
                default:
                    scalars.append(byte)
                }
            }
            throw ParseError(offset: index, reason: "unterminated string")
        }

        mutating func parseNumber() throws -> Value {
            let start = index
            while index < bytes.count, "+-0123456789.eE".utf8.contains(bytes[index]) { index += 1 }
            guard index > start, let number = Double(String(decoding: bytes[start..<index], as: UTF8.self)) else {
                throw ParseError(offset: start, reason: "invalid number")
            }
            return .number(number)
        }
    }
}
