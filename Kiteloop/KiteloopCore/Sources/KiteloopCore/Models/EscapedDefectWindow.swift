import Foundation

/// The escaped-defect window itself — seven days, inclusive at the boundary —
/// held once, package-side, so `EscapedDefectReader`'s signal and
/// `TaskMetricStore.escapedDefectRate`'s metric (through
/// `EscapedDefectRate.standardWindow`, which reads this rather than restating
/// seven days) cannot drift apart on what counts as escaped.
package enum EscapedDefectWindow {
    package static let standard: TimeInterval = 7 * 24 * 60 * 60
}
