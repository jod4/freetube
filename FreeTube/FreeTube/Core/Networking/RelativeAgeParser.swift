import Foundation

/// Turns YouTube's relative "time posted" strings ("3 days ago", "vor 2 Wochen",
/// "Streamed 5 hours ago", "il y a 1 mois", "2 года назад") into an approximate age in seconds.
///
/// **Why:** channel listings only carry `timePosted` as display text in the request locale
/// (YouTubeKit sends the device language), never a timestamp. The local subscriptions feed needs
/// a sortable key to interleave videos from many channels, and an approximate age is enough —
/// within one channel the listing order is already newest-first and is used as the tie-breaker.
///
/// Covers the app's five UI languages (en / de / es / fr / ru). Unknown phrasing returns nil and
/// the caller sorts those items last.
nonisolated enum RelativeAgeParser {
    private static let minute: TimeInterval = 60
    private static let hour: TimeInterval = 3_600
    private static let day: TimeInterval = 86_400

    /// Word-prefix → unit length. First prefix match on any token wins. Words too short to be
    /// safe as prefixes (French "an", Spanish "mes") are matched exactly in `exactUnits`.
    private static let prefixUnits: [(String, TimeInterval)] = [
        // seconds
        ("second", 1), ("sekund", 1), ("segund", 1), ("секунд", 1),
        // minutes
        ("minut", minute), ("минут", minute),
        // hours
        ("hour", hour), ("stund", hour), ("hora", hour), ("heure", hour), ("час", hour),
        // days
        ("day", day), ("tag", day), ("día", day), ("dia", day), ("jour", day),
        ("дн", day), ("ден", day),
        // weeks
        ("week", 7 * day), ("woche", 7 * day), ("semana", 7 * day), ("semaine", 7 * day),
        ("недел", 7 * day),
        // months
        ("month", 30 * day), ("monat", 30 * day), ("mese", 30 * day), ("mois", 30 * day),
        ("месяц", 30 * day),
        // years
        ("year", 365 * day), ("jahr", 365 * day), ("año", 365 * day), ("ano", 365 * day),
        ("année", 365 * day), ("год", 365 * day), ("лет", 365 * day)
    ]

    private static let exactUnits: [String: TimeInterval] = [
        "mes": 30 * day,
        "an": 365 * day, "ans": 365 * day
    ]

    /// Approximate age in seconds, or nil when the string has no recognisable unit.
    static func age(from text: String?) -> TimeInterval? {
        guard let text, !text.isEmpty else { return nil }
        let lowered = text.lowercased()
        let tokens = lowered
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }

        // Prefix pass first, exact pass second: English "an hour ago" must resolve to hours,
        // not to French "an" (= year).
        var unit: TimeInterval?
        prefixLoop: for token in tokens {
            for (prefix, length) in prefixUnits where token.hasPrefix(prefix) {
                unit = length
                break prefixLoop
            }
        }
        if unit == nil {
            unit = tokens.lazy.compactMap { exactUnits[$0] }.first
        }
        guard let unit else { return nil }

        // First integer in the string; phrasing without a digit ("a day ago", "vor einem Tag")
        // means one unit.
        let digits = lowered
            .components(separatedBy: CharacterSet.decimalDigits.inverted)
            .first { !$0.isEmpty }
        let count = digits.flatMap { Double($0) } ?? 1
        return count * unit
    }
}
