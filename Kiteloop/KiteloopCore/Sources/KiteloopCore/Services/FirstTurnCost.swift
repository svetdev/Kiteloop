import Foundation

/// What an agent's configuration puts in its context before anyone speaks,
/// part by part: the sections of the system prompt Kiteloop composes for it.
///
/// The figure is a size, in bytes of UTF-8 text, because that is what can be
/// measured without the model's tokenizer; a token count would be a guess.
/// ``ContextOccupancy`` is the measured token figure, once a turn has run.
package struct FirstTurnCost: Equatable, Sendable {
    package struct Section: Equatable, Sendable {
        package let name: String
        package let bytes: Int
    }

    /// The sections that have text, in the order they were given.
    package let sections: [Section]

    package init(sections: [(name: String, text: String)]) {
        self.sections = sections
            .map { Section(name: $0.name, bytes: $0.text.utf8.count) }
            .filter { $0.bytes > 0 }
    }

    package var total: Int { sections.reduce(0) { $0 + $1.bytes } }

    package var json: [String: Any] {
        ["bytes": total,
         "sections": sections.map { ["name": $0.name, "bytes": $0.bytes] as [String: Any] }]
    }
}
