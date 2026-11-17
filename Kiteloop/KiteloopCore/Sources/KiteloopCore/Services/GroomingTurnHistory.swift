import Foundation

/// What a groomer is told about the worker it is sizing an item for: how many
/// turns that worker gets on one item, and how many turns this project's runs
/// of each declared size actually took.
///
/// A size is a promise that a worker finishes the item inside its turn budget,
/// and the groomer was asked for one without being told the budget or how the
/// sizes it had already handed out fared against it. Every figure here is one
/// the app already holds — the budget is the worker's derived one, the rows
/// are read off run records — so nothing is a number of this type's own.
package struct GroomingTurnHistory: Sendable, Equatable {

    /// One run that both declared a size and reported its worker's turns.
    package struct Sample: Sendable, Equatable {
        /// The item's declared size as recorded, `ItemSize.rawValue`.
        package let size: String
        package let turns: Int
        /// Whether a turn cap cut the worker short. An unrecorded answer is
        /// not a cut-short run.
        package let cutShort: Bool

        package init(size: String, turns: Int, cutShort: Bool) {
            self.size = size
            self.turns = turns
            self.cutShort = cutShort
        }
    }

    /// What the runs of one declared size took.
    package struct Row: Sendable, Equatable {
        /// `ItemSize.rawValue`.
        package let size: String
        package let runs: Int
        /// The middle run's turns; of an even number of runs, the mean of the
        /// middle two, rounded down.
        package let median: Int
        package let most: Int
        package let cutShort: Int

        package init(size: String, runs: Int, median: Int, most: Int, cutShort: Int) {
            self.size = size
            self.runs = runs
            self.median = median
            self.most = most
            self.cutShort = cutShort
        }
    }

    /// The turns a worker gets on one item.
    package let budget: Int
    /// One row per size that has a run, in `ItemSize` order.
    package let rows: [Row]

    package init(budget: Int, rows: [Row]) {
        self.budget = budget
        self.rows = rows
    }

    /// Groups `samples` by declared size, in `ItemSize` order. A sample whose
    /// size is not an `ItemSize` belongs to no row.
    package init(samples: [Sample], budget: Int) {
        self.budget = budget
        self.rows = ItemSize.allCases.compactMap { size in
            Self.row(size: size, samples: samples.filter { ItemSize(rawValue: $0.size.uppercased()) == size })
        }
    }

    private static func row(size: ItemSize, samples: [Sample]) -> Row? {
        let turns = samples.map(\.turns).sorted()
        guard let most = turns.last else { return nil }
        let middle = turns.count / 2
        let median = turns.count.isMultiple(of: 2) ? (turns[middle - 1] + turns[middle]) / 2 : turns[middle]
        return Row(size: size.rawValue, runs: turns.count, median: median, most: most,
                   cutShort: samples.filter(\.cutShort).count)
    }

    /// The section of the grooming prompt that states all of it, and what to
    /// do with an item that will not fit.
    package var promptSection: String {
        let measured = rows.isEmpty
            ? "This project has no measured runs yet, so there is no record of what each size took."
            : "What this project's recorded runs took, by the size the item declared:\n"
                + rows.map(Self.line).joined(separator: "\n")
        return """
        A worker gets \(budget) turns on one item, and a run that reaches the turn limit is cut \
        off with the work unfinished.
        \(measured)
        Size the item to what a worker finishes inside that budget. If it will not fit, propose \
        a first slice that does — complete on its own, with its own Validation — and list the \
        rest under Out of Scope.
        """
    }

    private static func line(_ row: Row) -> String {
        "\(row.size): \(row.runs) \(row.runs == 1 ? "run" : "runs"), median \(row.median), "
            + "most \(row.most), \(row.cutShort) cut short at the turn limit"
    }
}
