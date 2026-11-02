import Foundation

/// A released version, as the update check has to compare them: the app's own
/// `MARKETING_VERSION` (`0.4.8`) against the tag a GitHub release carries
/// (`v0.4.8`).
///
/// Comparison is component-by-component and numeric, because string ordering
/// gets the case that matters wrong — `"0.4.10" < "0.4.9"` lexically, so a
/// tenth patch release would never be offered. A missing component reads as
/// zero, so `0.5` and `0.5.0` are the same version.
struct ReleaseVersion: Equatable, Comparable {
    /// `0.4.8` → `[0, 4, 8]`. Never empty.
    let components: [Int]

    /// `nil` for anything that is not a plain numeric version: an unbundled
    /// build's `"dev"`, an empty tag, a release tagged after something other
    /// than its number, a pre-release suffix like `0.5.0-beta`. A version
    /// neither side can read is not a version either side can be newer than,
    /// and `isNewer` says no rather than guessing.
    init?(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.first == "v" || trimmed.first == "V" { trimmed.removeFirst() }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var numbers: [Int] = []
        for part in parts {
            // `Int` rejects "", "beta", "1-rc" and anything that overflows;
            // the sign check rejects "-1", which `Int` would happily read.
            guard let number = Int(part), number >= 0 else { return nil }
            numbers.append(number)
        }
        components = numbers
    }

    static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        ordering(lhs, rhs) == 0
    }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        ordering(lhs, rhs) < 0
    }

    /// Negative, zero or positive, the usual three-way answer, over the two
    /// component lists padded to the same length with zeros.
    private static func ordering(_ lhs: ReleaseVersion, _ rhs: ReleaseVersion) -> Int {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right ? -1 : 1 }
        }
        return 0
    }

    /// Whether `latest` is worth telling someone running `current` about.
    ///
    /// False when either side is unreadable — an unbundled `"dev"` build, a
    /// tag that is not a version — so the notice is only ever raised on an
    /// actual comparison, and false when they are equal or when the installed
    /// copy is somehow ahead of the published one.
    static func isNewer(_ latest: String, than current: String) -> Bool {
        guard let latest = ReleaseVersion(latest), let current = ReleaseVersion(current) else { return false }
        return current < latest
    }
}
