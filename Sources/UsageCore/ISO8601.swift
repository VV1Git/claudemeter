import Foundation

/// Date parsing for the two timestamp shapes this app meets.
///
/// The usage API returns 6 fractional digits with a numeric offset
/// (`2026-07-29T20:19:59.582576+00:00`); transcripts return 3 fractional digits
/// with a `Z` suffix (`2026-07-29T19:23:56.813Z`). `ISO8601DateFormatter` handles
/// both, but only with `.withFractionalSeconds` set — and it *fails* on a
/// timestamp with no fractional part when that option is on, so both variants are
/// kept and tried in order.
public enum ISO8601 {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let withoutFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let lock = NSLock()

    /// Thread-safe parse. `ISO8601DateFormatter` is not documented as Sendable, so
    /// access to the shared instances is serialised.
    public static func date(from string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return withFraction.date(from: string) ?? withoutFraction.date(from: string)
    }

    public static func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return withFraction.string(from: date)
    }
}

extension JSONDecoder {
    /// Decoder configured for both timestamp shapes above.
    public static func claudeMeter() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            // Samples we write ourselves round-trip as epoch seconds.
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            let raw = try container.decode(String.self)
            guard let date = ISO8601.date(from: raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Unparseable timestamp: \(raw)")
            }
            return date
        }
        return decoder
    }
}

extension JSONEncoder {
    public static func claudeMeter() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSince1970)
        }
        return encoder
    }
}
