import Foundation

/// The one-time move from "the Now epic" to `lane:now`.
///
/// Before lanes there was one way to say an item should run next: put it in an
/// epic called `Now`. That spent the epic — the only place a file records which
/// area an item is about — on an ordering decision, and the format already
/// carries the successor of that shape: `## Now` became `## Epic: Now` on the
/// first write-back, and this is the same migration one step on.
///
/// What it does **not** do is move the items home. Which area an item belongs
/// to is not written anywhere in the file, so nothing here could work it out;
/// the epic keeps its items exactly where they are, and moving them into their
/// area epics is a person's edit, made once, whenever they get to it. The lane
/// is what carries the meaning across in the meantime.
package enum BacklogLaneMigration {
    /// The epic name that used to mean "run this next", matched without regard
    /// to case: `## now`, `## Now` and `## Epic: Now` all name it.
    package static let nowEpicName = "Now"

    /// `file` with every item under an epic named `Now` marked `lane: .now`, or
    /// nil when there was nothing left to mark.
    ///
    /// Nil is the answer that makes this run **once**: the marks are written
    /// back to the file, so the next load finds every one of those items
    /// already `now`, changes nothing and writes nothing. A caller that writes
    /// on nil would rewrite the backlog on every read of it.
    package static func migrated(_ file: BacklogFile) -> BacklogFile? {
        var migrated = file
        var marked = false
        for sectionIndex in migrated.sections.indices where isNowEpic(migrated.sections[sectionIndex].name) {
            for itemIndex in migrated.sections[sectionIndex].items.indices
            where migrated.sections[sectionIndex].items[itemIndex].lane != .now {
                migrated.sections[sectionIndex].items[itemIndex].lane = .now
                marked = true
            }
        }
        return marked ? migrated : nil
    }

    package static func isNowEpic(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(nowEpicName) == .orderedSame
    }
}
