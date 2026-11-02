import Foundation

/// A kept QA storyboard read back for whoever approves the item: the steps QA
/// judged, in the order they were taken, each with its caption and picture.
/// `QAStoryboardArchive` keeps the page; this finds and reads it.
package struct QAStoryboardPage: Equatable, Sendable {
    package struct Step: Equatable, Sendable {
        package let number: Int
        package let caption: String
        /// The step's screenshot, resolved against the page's folder. Nil when
        /// the page names none or the file is not on disk.
        package let picture: URL?

        /// `QAStoryboardTestCase` captions the picture a failing step takes
        /// `FAILED: <caption> — <why>`.
        package var failed: Bool { caption.hasPrefix("FAILED") }
    }

    package let url: URL
    package let steps: [Step]

    /// The page the item's newest QA run kept, or nil when no run kept one.
    /// Newest by the page's modification date: run ids say nothing about order.
    package static func latest(home: URL = KiteloopHome.url, itemID: String) -> URL? {
        let runs = home.appending(path: ".kiteloop/storyboards", directoryHint: .isDirectory)
            .appending(path: itemID, directoryHint: .isDirectory)
        return contents(of: runs)
            .flatMap { contents(of: $0).filter { $0.pathExtension == "md" && isFile($0) } }
            .max { modified($0).compare(modified($1)) == .orderedAscending }
    }

    /// The page at `url`, its steps in page order. Nil when it cannot be read.
    package static func read(_ url: URL) -> QAStoryboardPage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let folder = url.deletingLastPathComponent()
        var steps: [Step] = []
        var heading: (number: Int, caption: String)?
        for line in String(decoding: data, as: UTF8.self).components(separatedBy: .newlines) {
            if let match = line.wholeMatch(of: /## (\d+)\. (.*)/), let number = Int(match.1) {
                heading.map { steps.append(Step(number: $0.number, caption: $0.caption, picture: nil)) }
                heading = (number, String(match.2))
            } else if let open = heading, let match = line.wholeMatch(of: /!\[.*\]\((.+)\)/) {
                steps.append(Step(number: open.number, caption: open.caption,
                                  picture: existing(String(match.1), in: folder)))
                heading = nil
            }
        }
        heading.map { steps.append(Step(number: $0.number, caption: $0.caption, picture: nil)) }
        return QAStoryboardPage(url: url, steps: steps)
    }

    private static func existing(_ path: String, in folder: URL) -> URL? {
        let picture = URL(filePath: path, relativeTo: folder).standardizedFileURL
        return FileManager.default.fileExists(atPath: picture.path(percentEncoded: false)) ? picture : nil
    }

    private static func contents(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [
            .isRegularFileKey, .contentModificationDateKey,
        ])) ?? []
    }

    private static func isFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
