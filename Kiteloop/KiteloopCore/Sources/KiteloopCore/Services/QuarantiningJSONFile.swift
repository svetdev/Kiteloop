import Foundation

/// Reads one of Kiteloop's small JSON stores, and keeps the file when the
/// decoder refuses it.
///
/// The shape this replaces is `try? JSONDecoder().decode(…)` inside a `guard`
/// that returns — `GlobalConfigStore.load()` is the canonical one. A file the
/// decoder cannot read is then indistinguishable from no file at all: the store
/// comes up on its defaults, nothing anywhere says why, and the first save
/// writes those defaults over the bytes a human or a later migration could have
/// repaired. One truncated `global-config.json` costs the knowledge repo path,
/// the backend choice and the control-server settings, permanently, in silence.
///
/// So a refusal moves the file aside to `<name>.unreadable-<timestamp>` beside
/// itself, reports through ``StoreProblemReporter`` — naming the store, the file
/// and where it went — and answers nil. The caller still starts fresh, which is
/// the only thing it can do; what changes is that the evidence survives the next
/// save and the human is told.
///
/// Deliberately *not* handled here: repairing or migrating what was quarantined,
/// and pruning the aside files. A file moved aside is the human's to look at.
package enum QuarantiningJSONFile {

    /// What a caller could not read, in the words the notification and the
    /// Diagnostics line print — the decoding error is the useful half, and where
    /// the file went is what makes the report actionable.
    package enum Problem: Error, CustomStringConvertible {
        /// The decoder refused the file and the original is preserved at `movedTo`.
        case undecodable(decoding: Error, movedTo: URL)
        /// The decoder refused the file and it could not be moved aside, so the
        /// next save will overwrite it. Both halves are reported: the second is
        /// why the first is about to become unrecoverable.
        case undecodableAndNotMovedAside(decoding: Error, move: Error)

        package var description: String {
            switch self {
            case let .undecodable(decoding, movedTo):
                return "not valid JSON for this store (\(decoding)) — moved aside to "
                    + movedTo.path(percentEncoded: false)
            case let .undecodableAndNotMovedAside(decoding, move):
                return "not valid JSON for this store (\(decoding)) — and could not be moved aside "
                    + "(\(move)), so the next save will overwrite it"
            }
        }
    }

    /// One read's outcome: what decoded, and — for a caller that has to *act* on
    /// a failure rather than only have it reported — what went wrong.
    ///
    /// ``DailySpendLedger`` is why the problem is handed back at all: a day whose
    /// spend could not be read is not a day on which nothing was spent, and the
    /// ledger refuses an autonomous start while that is so. Most callers can only
    /// start fresh and are served by ``load(_:from:store:decoder:reporter:now:)``.
    package struct Outcome<Value> {
        /// What decoded, or nil when there was nothing to decode.
        package var value: Value?
        /// What went wrong, in the same words the reporter logged — nil when
        /// there was nothing to say: no file at all, or a file that decoded.
        package var problem: String?
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(value: Value? = nil, problem: String? = nil) {
            self.value = value
            self.problem = problem
        }
    }

    /// Decodes `Value` from the JSON at `url`, or answers nil having said why.
    ///
    /// Nil comes back for three different situations, and only two of them are
    /// problems:
    /// - **No file.** Every one of these stores is created by its first save, so
    ///   a missing file is the ordinary first-launch state and is silent.
    /// - **A file that cannot be read at all** — a directory in its place, a
    ///   permission that was tightened. Reported, and *not* moved: there is
    ///   nothing here that a move would rescue, and moving what we could not read
    ///   is as likely to lose it as to keep it.
    /// - **A file the decoder refuses.** Moved aside, then reported.
    ///
    /// `store` is the store's name as a human says it — "Settings", not
    /// `GlobalConfigStore` — since it is read in a notification title and is half
    /// the reporter's dedup key.
    ///
    /// `now` is a parameter so a test can put two failures in the same second on
    /// purpose; nothing else should pass it.
    package static func load<Value: Decodable>(_ type: Value.Type,
                                       from url: URL,
                                       store: String,
                                       decoder: JSONDecoder = JSONDecoder(),
                                       reporter: StoreProblemReporter = .shared,
                                       now: Date = Date()) -> Value? {
        read(type, from: url, store: store, decoder: decoder, reporter: reporter, now: now).value
    }

    /// The same read, handing the problem back as well as reporting it. See
    /// ``load(_:from:store:decoder:reporter:now:)`` for what the three nil cases
    /// mean; only the two that are problems fill ``Outcome/problem``.
    package static func read<Value: Decodable>(_ type: Value.Type,
                                       from url: URL,
                                       store: String,
                                       decoder: JSONDecoder = JSONDecoder(),
                                       reporter: StoreProblemReporter = .shared,
                                       now: Date = Date()) -> Outcome<Value> {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return Outcome()
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            reporter.report(store: store, operation: .read, url: url, error: error)
            return Outcome(problem: String(describing: error))
        }

        do {
            return Outcome(value: try decoder.decode(Value.self, from: data))
        } catch let decodingError {
            let problem: Problem
            do {
                problem = .undecodable(decoding: decodingError, movedTo: try quarantine(url, now: now))
            } catch {
                problem = .undecodableAndNotMovedAside(decoding: decodingError, move: error)
            }
            reporter.report(store: store, operation: .read, url: url, error: problem)
            return Outcome(problem: problem.description)
        }
    }

    // MARK: - Moving the file aside

    /// Renames `url` to `<name>.unreadable-<timestamp>` in its own directory and
    /// answers where it landed.
    ///
    /// A sibling rather than a temp directory, for the same reason
    /// ``AtomicFileWriter`` writes its temp file as one: a rename across volumes
    /// fails, and the file the human wants is next to the one they were looking
    /// at anyway.
    ///
    /// The timestamp is to the second, so two refusals close together would name
    /// the same file — and a plain rename would silently drop the first one,
    /// which is the destruction this whole type exists to prevent. `moveItem`
    /// fails rather than overwrites when the destination is taken, so the counter
    /// is driven by that failure rather than by a prior existence check: nothing
    /// can slip in between the two.
    private static func quarantine(_ url: URL, now: Date) throws -> URL {
        let directory = url.deletingLastPathComponent()
        let base = "\(url.lastPathComponent).unreadable-\(stamp(now))"

        for attempt in 1...maximumQuarantineAttempts {
            let destination = directory.appending(path: attempt == 1 ? base : "\(base)-\(attempt)")
            do {
                try FileManager.default.moveItem(at: url, to: destination)
                return destination
            } catch let error as NSError
                where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                if attempt == maximumQuarantineAttempts { throw error }
            }
        }
        // Unreachable: the loop either returns or throws on its last attempt.
        throw CocoaError(.fileWriteFileExists)
    }

    /// Enough that a store failing repeatedly within one second still keeps every
    /// copy, and few enough that a directory somehow full of them cannot spin.
    private static let maximumQuarantineAttempts = 100

    /// Sortable, second-resolution, and safe in a filename: `20260813T091530Z`.
    /// UTC so files quarantined either side of a DST change still sort by when
    /// they happened.
    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }
}
