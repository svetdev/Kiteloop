import Foundation

/// The one more pass a worker gets when its turn budget ran out with work
/// already in its worktree.
///
/// A worker that used every turn it had was blocked where it stood, and the
/// next run of the item began on a fresh branch and replaced what the first
/// had written — the same work paid for twice. So a cut-short worker that
/// left something behind is started once more in the same worktree, told the
/// work is there. Once, because the item is either nearly finished or too big
/// for its budget, and a second continuation would only be a larger budget by
/// another name. A continuation that is cut short as well, or that leaves the
/// tree exactly as it found it, ends where the first pass would have: the item
/// blocked, saying the worker was cut short.
///
/// Nothing here spends: the pass runs under the same cost caps and the same
/// stall watchdog as the one before it, and what the first pass cost is
/// counted with it.
package enum CutShortContinuation {

    /// What opens the worker's brief on the continuation pass.
    package static let note = """
        ## Continuing unfinished work
        An earlier pass at this item ran out of turns before it finished. What \
        it wrote is still here, in this worktree and on this branch — \
        uncommitted changes and any commits it made. Read `git status` and \
        `git log` first, then finish the work from where it stands. Do not \
        start over, and do not redo what is already done.
        """

    /// Whether a pass that just ended is followed by a continuation: its
    /// worker was cut short by a turn cap, it left work in the worktree, and
    /// the item has not been continued already.
    package static func isDue(cutShortTurns: Int?, hasWork: Bool, alreadyContinued: Bool) -> Bool {
        cutShortTurns != nil && hasWork && !alreadyContinued
    }

    /// The turn budget an item that has been continued blocks on, or nil when
    /// the continuation moved the work on and the run carries on as any other.
    ///
    /// A continuation cut short itself blocks on its own budget. One that was
    /// not, but left the tree as it found it, blocks on the first pass's: it
    /// added nothing to work its worker had already called unfinished. A tree
    /// nobody could read is not progress either — only a difference is.
    package static func blockingTurns(firstPassTurns: Int, continuationTurns: Int?,
                                      before: TreeMark?, after: TreeMark?) -> Int? {
        if let continuationTurns { return continuationTurns }
        guard let before, let after, before != after else { return firstPassTurns }
        return nil
    }

    /// A worktree as it stands: the commit it is on, what its tracked files
    /// differ from that commit by, and each untracked file's size and
    /// modification time. Two marks are equal when nothing was committed,
    /// edited, added or removed between them.
    package struct TreeMark: Equatable, Sendable {
        package let head: String
        package let diff: String
        package let untracked: [String]

        package init(head: String, diff: String, untracked: [String]) {
            self.head = head
            self.diff = diff
            self.untracked = untracked
        }
    }

    /// Reads `worktree`'s mark, or nil when git could not answer one of the
    /// three questions. Synchronous — call it off the main actor.
    package static func treeMark(worktree: URL) -> TreeMark? {
        let root = worktree.path(percentEncoded: false)
        let head = SubprocessOutput.git(["-C", root, "rev-parse", "HEAD"])
        let diff = SubprocessOutput.git(["-C", root, "diff", "--binary", "HEAD"])
        let others = SubprocessOutput.git(["-C", root, "ls-files", "--others", "--exclude-standard", "-z"])
        guard head.status == 0, diff.status == 0, others.status == 0 else { return nil }
        let untracked = others.output.split(separator: "\0").map { path -> String in
            let file = worktree.appending(path: String(path)).path(percentEncoded: false)
            let attributes = try? FileManager.default.attributesOfItem(atPath: file)
            let size = (attributes?[.size] as? NSNumber)?.int64Value
            let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970
            return "\(path) \(size.map(String.init) ?? "-") \(modified.map { String($0) } ?? "-")"
        }
        return TreeMark(head: head.output.trimmingCharacters(in: .whitespacesAndNewlines),
                        diff: diff.output, untracked: untracked)
    }
}
