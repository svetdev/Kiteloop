import Foundation

/// Where an isolated run's Xcode build output goes — and how it stops outliving
/// the checkout that produced it.
///
/// A worktree run's `verify:` is an `xcodebuild` of the *worktree's* copy of the
/// project. Xcode derives DerivedData from the project's path, so every run used
/// to mint its own `~/Library/Developer/Xcode/DerivedData/<Project>-<hash>` tree
/// and its own `.app` — which LaunchServices then registered under the same
/// bundle id as the real one. Two costs, both measured on 2026-08-06: 113 trees
/// of dead build output, and `open -a Kiteloop` resolving by bundle id to a
/// two-day-old binary out of a long-merged worktree, so a session's worth of
/// fixes was judged from a build that never contained them.
///
/// The fix is to point the worktree's builds at a DerivedData path *inside the
/// worktree* — under its already-gitignored `.kiteloop/` — so the output is
/// destroyed with the checkout, and to drop the LaunchServices registration
/// before the bundle disappears. A build from the project root is untouched: its
/// DerivedData tree is the one that should exist.
package enum WorktreeBuildOutput {
    /// The disposable DerivedData directory for a worktree. Inside `.kiteloop/`
    /// because that path is already gitignored, so a build can't dirty the
    /// worktree's `git status` and make teardown think the run left work behind.
    package static func derivedDataDirectory(for worktree: URL) -> URL {
        worktree.appending(path: ".kiteloop/DerivedData")
    }

    // MARK: - Redirecting builds

    /// Rewrites `command` so every `xcodebuild` in it builds into `worktree`'s own
    /// DerivedData. A live-tree run (nil `worktree`) is returned unchanged — there
    /// is nothing disposable to redirect into.
    package static func redirectingBuilds(in command: String, worktree: URL?) -> String {
        guard let worktree else { return command }
        return redirectingBuilds(
            in: command,
            toDerivedDataPath: derivedDataDirectory(for: worktree).path(percentEncoded: false)
        )
    }

    /// Inserts `-derivedDataPath <path>` after each `xcodebuild` in the command.
    ///
    /// Two things are deliberately left alone: a command that already names a
    /// `-derivedDataPath` (an item that chose its own path keeps it, and applying
    /// this twice is a no-op), and the word `xcodebuild` anywhere other than the
    /// front of a command — quoted, or an argument to something else — so
    /// `grep xcodebuild build.log` stays a grep.
    package static func redirectingBuilds(in command: String, toDerivedDataPath path: String) -> String {
        guard !command.contains(derivedDataFlag) else { return command }
        let injection = " \(derivedDataFlag) \(shellQuoted(path))"

        var result = ""
        var word = ""
        /// Whether the word being read starts a command, rather than being an
        /// argument to one. Only the former can be the `xcodebuild` we mean.
        var atCommandStart = true

        func flush() {
            guard !word.isEmpty else { return }
            result += word
            if atCommandStart, isXcodebuild(word) {
                result += injection
            }
            atCommandStart = atCommandStart && preservesCommandStart(word)
            word = ""
        }

        var quote: Character?
        var escaped = false
        for character in command {
            if escaped {
                word.append(character)
                escaped = false
                continue
            }
            if let open = quote {
                word.append(character)
                if character == open { quote = nil }
                continue
            }
            switch character {
            case "\\":
                word.append(character)
                escaped = true
            case "'", "\"":
                quote = character
                word.append(character)
            case " ", "\t":
                flush()
                result.append(character)
            case ";", "&", "|", "(", ")", "\n":
                flush()
                result.append(character)
                atCommandStart = true
            default:
                word.append(character)
            }
        }
        flush()
        return result
    }

    private static let derivedDataFlag = "-derivedDataPath"

    /// Wrappers that run whatever follows them, so the next word is still the
    /// command. `cd Kiteloop && xcrun xcodebuild …` is the shape that matters.
    private static let commandWrappers: Set<String> = [
        "xcrun", "env", "nice", "time", "caffeinate", "arch", "sudo", "command",
    ]

    private static func isXcodebuild(_ word: String) -> Bool {
        word == "xcodebuild" || word.hasSuffix("/xcodebuild")
    }

    /// True for a word that doesn't consume the command slot: a wrapper, or a
    /// `FOO=bar` environment assignment sitting in front of the real command.
    private static func preservesCommandStart(_ word: String) -> Bool {
        if commandWrappers.contains(word) { return true }
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        return !word.hasPrefix("-")
    }

    /// Single-quotes `value` for `/bin/zsh -lc`. Worktree paths come from item ids
    /// and a project root a human chose, so a quote in one is unlikely — but an
    /// unquoted space would silently truncate the flag's argument.
    package static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Teardown

    /// Unregisters the worktree's built app bundles from LaunchServices and
    /// deletes its build output. Called before the checkout is removed: once the
    /// bundle is gone the registration can't be looked up by path any more, and a
    /// stale one is exactly what makes `open -a <App>` a coin flip.
    ///
    /// Covers both places the run's output can be. The redirected builds put it in
    /// the worktree; an `xcodebuild` that slipped through un-redirected (an agent
    /// typing its own build line) still minted a tree in the user's DerivedData,
    /// and that one outlives the checkout, so it is the one worth chasing.
    ///
    /// Safe to call on a worktree that never built anything — there is simply
    /// nothing to find, and nothing happens.
    package static func release(for worktree: URL, derivedDataRoot: URL = defaultUserDerivedDataRoot) {
        let fileManager = FileManager.default
        let trees = userDerivedDataTrees(builtFrom: worktree, derivedDataRoot: derivedDataRoot)
        for directory in [derivedDataDirectory(for: worktree)] + trees {
            guard fileManager.fileExists(atPath: directory.path(percentEncoded: false)) else { continue }
            unregisterFromLaunchServices(appBundles(inDerivedDataAt: directory))
            try? fileManager.removeItem(at: directory)
        }
    }

    /// The user's own DerivedData trees whose source project sits inside
    /// `worktree`. Xcode records that source in each tree's `info.plist`, so this
    /// is an exact match on provenance rather than a guess from the tree's name —
    /// and a path *inside* the worktree can only have come from this worktree.
    package static func userDerivedDataTrees(
        builtFrom worktree: URL,
        derivedDataRoot: URL = defaultUserDerivedDataRoot
    ) -> [URL] {
        let prefix = containmentPrefix(for: worktree)
        let trees = (try? FileManager.default.contentsOfDirectory(
            at: derivedDataRoot,
            includingPropertiesForKeys: nil
        )) ?? []
        return trees.filter { tree in
            guard let plist = NSDictionary(contentsOf: tree.appending(path: "info.plist")),
                  let workspace = plist["WorkspacePath"] as? String
            else { return false }
            return workspace.hasPrefix(prefix)
        }
    }

    /// `worktree`'s path with exactly one trailing separator, so `hasPrefix`
    /// against it means "inside this worktree" rather than "starts with these
    /// characters" — without it, a sibling worktree named `some-item-2` would
    /// match `some-item` and teardown would delete another run's build output.
    ///
    /// The trailing slash has to be trimmed before one is appended, not assumed
    /// absent: `standardizedFileURL` resolves against the filesystem, and a path
    /// that exists as a directory — which a worktree being torn down always does
    /// — comes back already ending in `/`. Concatenating another produced
    /// `…/some-item//`, a prefix of nothing Xcode ever writes, so every tree was
    /// filtered out and the escaped ones were left in `~/Library` for ever.
    private static func containmentPrefix(for worktree: URL) -> String {
        var path = worktree.standardizedFileURL.path(percentEncoded: false)
        while path.hasSuffix("/") { path.removeLast() }
        return path + "/"
    }

    package static var defaultUserDerivedDataRoot: URL {
        KiteloopHome.url
            .appending(path: "Library/Developer/Xcode/DerivedData")
    }

    /// The `.app` bundles a build left under `derivedData`, i.e. the ones that
    /// registered themselves with LaunchServices. Products live one directory per
    /// configuration (`Build/Products/Debug/…`), so this looks exactly two levels
    /// deep rather than walking a tree that holds tens of thousands of files.
    package static func appBundles(inDerivedDataAt derivedData: URL) -> [URL] {
        let products = derivedData.appending(path: "Build/Products")
        let fileManager = FileManager.default
        let configurations = (try? fileManager.contentsOfDirectory(
            at: products,
            includingPropertiesForKeys: nil
        )) ?? []
        return configurations.flatMap { configuration in
            ((try? fileManager.contentsOfDirectory(
                at: configuration,
                includingPropertiesForKeys: nil
            )) ?? []).filter { $0.pathExtension == "app" }
        }
    }

    /// `lsregister -u` each bundle. Best-effort: a machine without the tool, or a
    /// bundle LaunchServices never saw, is not a reason to abandon a teardown.
    package static func unregisterFromLaunchServices(_ bundles: [URL]) {
        guard !bundles.isEmpty,
              FileManager.default.isExecutableFile(atPath: Self.lsregisterPath)
        else { return }
        for bundle in bundles {
            _ = try? SubprocessOutput.run(
                executable: Self.lsregisterPath,
                arguments: ["-u", bundle.path(percentEncoded: false)]
            )
        }
    }

    package static let lsregisterPath =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
}
