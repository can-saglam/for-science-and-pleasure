import Foundation

/// One column's value as JSON, compared by value.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

/// A save as columns.
public typealias Fields = [String: JSONValue]

/// How a phone's copy of a save and the server's come together, column by
/// column, so two people changing different things on the same save both
/// keep their change.
///
/// Each phone remembers the server's copy as it last saw it (the base).
/// What differs from the base on the phone is an edit not yet sent; what
/// differs on the server is someone else's. Only the phone's edits are
/// sent, and a pull takes the server's columns except those.
public enum RowMerge {
    /// Columns people (or the phone, for a picture) change. Everything else
    /// is the server's to stamp: who and when, the library, the email it no
    /// longer keeps.
    public static let edited: Set<String> = [
        "kind", "status", "title", "summary", "venue", "area", "address", "category", "price", "url",
        "image_url", "starts_on", "ends_on", "reminder_offset_days", "reminder_anchor", "remind_at",
        "remind_time", "plan_on", "plan_time", "went_on", "notes", "color", "source", "lat", "lng",
        "place_id", "showings", "deleted_at",
    ]

    /// Columns a null never clears on the server (0041, 0044): only moving
    /// the save does, server-side. A null here is no edit, or it would be
    /// sent, ignored, and sent again on every sync.
    public static let keptOnNull: Set<String> = ["place_id", "showings"]

    /// This phone's edits since the server last saw the save.
    public static func changes(base: Fields, local: Fields) -> Fields {
        var out: Fields = [:]
        for key in edited {
            let mine = local[key] ?? .null
            guard mine != (base[key] ?? .null), !(mine == .null && keptOnNull.contains(key)) else { continue }
            out[key] = mine
        }
        return out
    }

    /// The save after a pull: the server's copy, with this phone's unsent
    /// edits on top. A plan and its time travel together, as do a
    /// reminder's day, time and rule: half of one from each side would be
    /// a plan or reminder nobody set.
    public static func merge(base: Fields, local: Fields, server: Fields) -> Fields {
        var out = server
        var mine = changes(base: base, local: local)
        for group in together where group.contains(where: { mine[$0] != nil }) {
            for key in group { mine[key] = local[key] ?? .null }
        }
        for (key, value) in mine { out[key] = value }
        return out
    }

    /// Columns that only mean something as a set.
    static let together: [Set<String>] = [
        ["plan_on", "plan_time"],
        ["reminder_offset_days", "reminder_anchor", "remind_at", "remind_time"],
        ["starts_on", "ends_on"],
        ["lat", "lng"],
    ]

    /// Before a phone has a base for a save (a build from before this, or
    /// a save it made and hasn't sent): the newer copy wins whole, as it
    /// always did. Equal stamps keep the phone's copy, but take what the
    /// server fills in without a new stamp (a picture, a colour, a place).
    public static func wholeRow(local: Fields, server: Fields, localStamp: Date, serverStamp: Date) -> Fields {
        if serverStamp > localStamp { return server }
        guard serverStamp == localStamp else { return local }
        var out = local
        for key in ["image_url", "color", "place_id"] { out[key] = server[key] ?? .null }
        return out
    }
}
