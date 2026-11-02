import Foundation

extension String {
    /// A count and its noun, singular for exactly one and plural otherwise:
    /// "1 turn", "0 turns", "3 turns". The plural is the singular plus "s"
    /// unless an irregular one is given ("branch" / "branches").
    package init(count: Int, noun singular: String, plural: String? = nil) {
        self = "\(count) \(count == 1 ? singular : plural ?? singular + "s")"
    }
}
