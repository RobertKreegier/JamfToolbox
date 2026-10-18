import Foundation

/// An order-preserving JSON value.
///
/// Device records are shown to the user in the order Jamf sent them, which
/// `JSONSerialization`'s unordered dictionaries cannot do. Numbers keep their
/// original text so `12` stays `12` and `1.5` stays `1.5`.
public enum JSONValue {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([JSONValue])
    case object([(key: String, value: JSONValue)])

    public static let emptyObject = JSONValue.object([])

    // MARK: Access

    public subscript(key: String) -> JSONValue? {
        if case .object(let entries) = self {
            return entries.first { $0.key == key }?.value
        }
        return nil
    }

    /// A copy of this object with `key` set (replacing any existing value).
    public func setting(_ key: String, to value: JSONValue) -> JSONValue {
        guard case .object(var entries) = self else { return self }
        if let index = entries.firstIndex(where: { $0.key == key }) {
            entries[index].value = value
        } else {
            entries.append((key, value))
        }
        return .object(entries)
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    public var isContainer: Bool {
        switch self {
        case .array, .object: return true
        default: return false
        }
    }

    /// The value as display text, with "empty" values collapsing to "".
    /// Mirrors the Python `value or ""` idiom: strings and numbers give their
    /// text, `true` gives "true", and null/false/containers give "".
    public var text: String {
        switch self {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b ? "true" : ""
        case .null, .array, .object: return ""
        }
    }

    /// One-line text for a tree row's value column.
    public var preview: String {
        switch self {
        case .object(let entries): return "{\(entries.count) field(s)}"
        case .array(let items): return "[\(items.count) item(s)]"
        case .null: return ""
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n
        case .string(let s): return s
        }
    }

    // MARK: Serialization

    /// Pretty-printed JSON (two-space indent), keys in their original order.
    public func prettyPrinted(level: Int = 0) -> String {
        let pad = String(repeating: "  ", count: level + 1)
        let closePad = String(repeating: "  ", count: level)
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n
        case .string(let s): return JSONValue.quote(s)
        case .array(let items):
            if items.isEmpty { return "[]" }
            let body = items.map { pad + $0.prettyPrinted(level: level + 1) }.joined(separator: ",\n")
            return "[\n\(body)\n\(closePad)]"
        case .object(let entries):
            if entries.isEmpty { return "{}" }
            let body = entries.map {
                pad + JSONValue.quote($0.key) + ": " + $0.value.prettyPrinted(level: level + 1)
            }.joined(separator: ",\n")
            return "{\n\(body)\n\(closePad)}"
        }
    }

    private static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    // MARK: Parsing

    public static func parse(_ data: Data) throws -> JSONValue {
        var parser = Parser(bytes: [UInt8](data))
        parser.skipWhitespace()
        let value = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.atEnd else { throw ParseError.trailingContent }
        return value
    }

    public enum ParseError: Error {
        case unexpectedEnd, unexpectedCharacter, invalidNumber, invalidEscape, tooDeep, trailingContent
    }

    private struct Parser {
        let bytes: [UInt8]
        var pos = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
            // Tolerate a UTF-8 byte-order mark.
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { pos = 3 }
        }

        var atEnd: Bool { pos >= bytes.count }

        mutating func skipWhitespace() {
            while pos < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[pos]) { pos += 1 }
        }

        mutating func parseValue(depth: Int) throws -> JSONValue {
            guard depth < 512 else { throw ParseError.tooDeep }
            guard pos < bytes.count else { throw ParseError.unexpectedEnd }
            switch bytes[pos] {
            case UInt8(ascii: "{"): return try parseObject(depth: depth)
            case UInt8(ascii: "["): return try parseArray(depth: depth)
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            default: return try parseNumber()
            }
        }

        mutating func expect(_ word: String) throws {
            for byte in word.utf8 {
                guard pos < bytes.count, bytes[pos] == byte else { throw ParseError.unexpectedCharacter }
                pos += 1
            }
        }

        mutating func parseObject(depth: Int) throws -> JSONValue {
            pos += 1  // {
            var entries: [(key: String, value: JSONValue)] = []
            skipWhitespace()
            if pos < bytes.count, bytes[pos] == UInt8(ascii: "}") { pos += 1; return .object(entries) }
            while true {
                skipWhitespace()
                guard pos < bytes.count else { throw ParseError.unexpectedEnd }
                guard bytes[pos] == UInt8(ascii: "\"") else { throw ParseError.unexpectedCharacter }
                let key = try parseString()
                skipWhitespace()
                guard pos < bytes.count, bytes[pos] == UInt8(ascii: ":") else { throw ParseError.unexpectedCharacter }
                pos += 1
                skipWhitespace()
                entries.append((key, try parseValue(depth: depth + 1)))
                skipWhitespace()
                guard pos < bytes.count else { throw ParseError.unexpectedEnd }
                if bytes[pos] == UInt8(ascii: ",") { pos += 1; continue }
                if bytes[pos] == UInt8(ascii: "}") { pos += 1; return .object(entries) }
                throw ParseError.unexpectedCharacter
            }
        }

        mutating func parseArray(depth: Int) throws -> JSONValue {
            pos += 1  // [
            var items: [JSONValue] = []
            skipWhitespace()
            if pos < bytes.count, bytes[pos] == UInt8(ascii: "]") { pos += 1; return .array(items) }
            while true {
                skipWhitespace()
                items.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                guard pos < bytes.count else { throw ParseError.unexpectedEnd }
                if bytes[pos] == UInt8(ascii: ",") { pos += 1; continue }
                if bytes[pos] == UInt8(ascii: "]") { pos += 1; return .array(items) }
                throw ParseError.unexpectedCharacter
            }
        }

        mutating func parseNumber() throws -> JSONValue {
            let start = pos
            while pos < bytes.count, "+-.eE0123456789".utf8.contains(bytes[pos]) { pos += 1 }
            guard pos > start else { throw ParseError.unexpectedCharacter }
            let text = String(decoding: bytes[start..<pos], as: UTF8.self)
            guard Double(text) != nil else { throw ParseError.invalidNumber }
            return .number(text)
        }

        mutating func parseString() throws -> String {
            pos += 1  // opening quote
            var buffer: [UInt8] = []
            while true {
                guard pos < bytes.count else { throw ParseError.unexpectedEnd }
                let byte = bytes[pos]
                pos += 1
                if byte == UInt8(ascii: "\"") { return String(decoding: buffer, as: UTF8.self) }
                guard byte == UInt8(ascii: "\\") else { buffer.append(byte); continue }
                guard pos < bytes.count else { throw ParseError.unexpectedEnd }
                let escape = bytes[pos]
                pos += 1
                switch escape {
                case UInt8(ascii: "\""): buffer.append(UInt8(ascii: "\""))
                case UInt8(ascii: "\\"): buffer.append(UInt8(ascii: "\\"))
                case UInt8(ascii: "/"): buffer.append(UInt8(ascii: "/"))
                case UInt8(ascii: "b"): buffer.append(0x08)
                case UInt8(ascii: "f"): buffer.append(0x0C)
                case UInt8(ascii: "n"): buffer.append(0x0A)
                case UInt8(ascii: "r"): buffer.append(0x0D)
                case UInt8(ascii: "t"): buffer.append(0x09)
                case UInt8(ascii: "u"):
                    var scalarValue = try parseHex4()
                    if (0xD800..<0xDC00).contains(scalarValue),
                       pos + 1 < bytes.count, bytes[pos] == UInt8(ascii: "\\"), bytes[pos + 1] == UInt8(ascii: "u") {
                        let save = pos
                        pos += 2
                        let low = try parseHex4()
                        if (0xDC00..<0xE000).contains(low) {
                            scalarValue = 0x10000 + ((scalarValue - 0xD800) << 10) + (low - 0xDC00)
                        } else {
                            pos = save  // not a pair; leave the second escape for the next pass
                        }
                    }
                    let scalar = Unicode.Scalar(scalarValue) ?? "\u{FFFD}"
                    buffer.append(contentsOf: Array(String(Character(scalar)).utf8))
                default:
                    throw ParseError.invalidEscape
                }
            }
        }

        mutating func parseHex4() throws -> UInt32 {
            guard pos + 4 <= bytes.count else { throw ParseError.unexpectedEnd }
            var value: UInt32 = 0
            for _ in 0..<4 {
                guard let digit = Character(UnicodeScalar(bytes[pos])).hexDigitValue else {
                    throw ParseError.invalidEscape
                }
                value = value * 16 + UInt32(digit)
                pos += 1
            }
            return value
        }
    }
}
