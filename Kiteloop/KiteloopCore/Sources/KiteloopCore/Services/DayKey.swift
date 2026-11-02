import Foundation

/// The Gregorian calendar day a moment falls in, as `yyyy-MM-dd` in Latin
/// digits — on every machine, whatever the Mac's region is set to.
///
/// A `DateFormatter` with `dateFormat = "yyyy-MM-dd"` and no `locale` set
/// inherits `Locale.current`, which carries both a calendar and a numbering
/// system: under a Japanese-calendar region `yyyy` is the era year, not the
/// Gregorian one, and under an Arabic-Indic numbering region the digits
/// aren't Latin. A day key is a storage format, not a display string — it has
/// to mean the same thing in every file it's written to regardless of who's
/// reading it back — so this builds the key from an explicitly Gregorian
/// `Calendar` instead, the same shape `DailySpendLedger.dayKey` already uses
/// for the same reason.
package enum DayKey {

    /// `date`'s calendar day in `timeZone`, as `yyyy-MM-dd`.
    package static func string(for date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
