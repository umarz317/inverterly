import Foundation

/// A decoded JSON tree. The vendor cloud is loose about types (a power reading is the string "1154",
/// a device code is the number 2452, a flag can be `false` or "false"), so the accessors coerce
/// instead of failing.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public static func parse(_ data: Data) throws -> JSONValue {
        JSONValue(any: try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    public static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }

    init(any: Any) {
        switch any {
        case let number as NSNumber:
            // JSONSerialization hands booleans back as NSNumber too; the CF type tells them apart.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map(JSONValue.init(any:)))
        case let object as [String: Any]:
            self = .object(object.mapValues(JSONValue.init(any:)))
        default:
            self = .null
        }
    }

    /// Member of an object. Nil when this is not an object, the key is absent or the value is null.
    public subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self, let value = object[key], value != .null else { return nil }
        return value
    }

    /// First member that exists, for fields the API spells more than one way (`devcode` / `devCode`).
    public subscript(any keys: String...) -> JSONValue? {
        for key in keys {
            if let value = self[key] { return value }
        }
        return nil
    }

    /// First member that is a non-empty text, the JS client's `a.title || a.desc || a.code`.
    public func firstText(_ keys: String...) -> String? {
        for key in keys {
            if let text = self[key]?.nonEmptyString { return text }
        }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let array) = self { return array }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let object) = self { return object }
        return nil
    }

    /// Text of a scalar. Numbers come back without a trailing ".0" so 2452 reads "2452".
    public var stringValue: String? {
        switch self {
        case .string(let string): return string
        case .number(let number): return JSONValue.plain(number)
        case .bool(let bool): return bool ? "true" : "false"
        case .null, .array, .object: return nil
        }
    }

    /// Like `stringValue`, but nil for an empty string too (the JS client's `a || b`).
    public var nonEmptyString: String? {
        guard let string = stringValue, !string.isEmpty else { return nil }
        return string
    }

    /// A number, or a string that is exactly a number ("233.3", " 86 ").
    public var doubleValue: Double? {
        switch self {
        case .number(let number):
            return number
        case .string(let string):
            let value = Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
            return (value?.isFinite ?? false) ? value : nil
        case .null, .bool, .array, .object:
            return nil
        }
    }

    public var intValue: Int? {
        guard let value = doubleValue, value.isFinite, abs(value) < 9e15 else { return nil }
        return Int(value.rounded(.towardZero))
    }

    /// `true`/`false`, 1/0, or "true"/"false"/"1"/"0".
    public var boolValue: Bool? {
        switch self {
        case .bool(let bool):
            return bool
        case .number(let number):
            return number != 0
        case .string(let string):
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        case .null, .array, .object:
            return nil
        }
    }

    /// A reading that may carry decoration ("990M", "52.7 V"): everything but digits, "." and "-"
    /// is dropped first, the way the JS client's `num()` does. Unlike the JS, an empty or
    /// unparseable value is nil rather than 0, so a missing reading is not shown as a real zero.
    public var looseNumber: Double? {
        switch self {
        case .number(let number):
            return number.isFinite ? number : nil
        case .string(let string):
            let kept = String(string.unicodeScalars.filter { ("0"..."9").contains($0) || $0 == "." || $0 == "-" })
            guard !kept.isEmpty, let value = Double(kept), value.isFinite else { return nil }
            return value
        case .null, .bool, .array, .object:
            return nil
        }
    }

    private static func plain(_ number: Double) -> String {
        if number.isFinite, number == number.rounded(), abs(number) < 9e15 {
            return String(Int64(number))
        }
        return String(number)
    }
}
