import Foundation

extension Int {
    /// Locale-aware abbreviated count — "1.2M" in English, "1,2 Mio." in German, "1,2 млн" in
    /// Russian. Use for view / subscriber / video counts shown next to a localized noun.
    var compactFormatted: String {
        formatted(.number.notation(.compactName))
    }
}
