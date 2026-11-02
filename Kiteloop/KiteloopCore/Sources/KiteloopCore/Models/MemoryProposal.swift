import Foundation

/// One proposed change to an agent's memory, waiting for a human.
///
/// It began as one shape — an agent asking for a fact to be *added* — and the
/// librarian needs three more: merge these duplicates, delete this fact the code
/// contradicts, archive this stale one. They all route through the same gate, so
/// they are the same record with an ``Operation`` on it rather than a second
/// approval path nobody would remember to look at.
///
/// ``operation``, ``source``, ``rationale`` and ``evidence`` are all decoded
/// leniently: proposals written before the librarian existed are on disk with
/// none of them, and they are exactly what `.add` from an agent means.
package struct MemoryProposal: Codable, Identifiable, Sendable, Equatable {
    package let id: String
    package let agentID: String
    package let timestamp: Date
    package let proposedContent: String
    /// The text actually written to memory, when a human edited the proposal
    /// before approving it — nil unless ``status`` is ``Status/edited``. The
    /// proposer's words stay in ``proposedContent`` beside it, so the record
    /// shows both what was asked for and what was approved.
    package var approvedContent: String?
    package var status: Status
    /// What approving this does to the index.
    package let operation: Operation
    /// Who wrote it — an agent about itself, or a librarian pass.
    package let source: Source
    /// Why this is being proposed, in the proposer's words. Shown beside the
    /// content so a human is not left to infer the reason for a deletion.
    package let rationale: String?
    /// What contradicts the fact a ``Operation/delete(topic:)`` removes.
    ///
    /// A deletion without it is not a deletion — see
    /// ``MemoryLibrarian/parse(_:corpus:)``, which turns one into an archival:
    /// "seems old" is a reason to stop injecting a fact, not to destroy it.
    package let evidence: String?

    package enum Status: String, Codable, Sendable {
        case pending
        case approved
        case rejected
        case edited
    }

    package enum Source: String, Codable, Sendable {
        /// An agent's own `propose_memory` call.
        case agent
        /// A consolidation pass over the corpus.
        case librarian
    }

    /// What approving does. The topic names are the slugs in square brackets on
    /// the index lines — the same names `recall_knowledge` answers to.
    package enum Operation: Codable, Sendable, Equatable {
        /// Record ``proposedContent`` as a new fact. The original behaviour, and
        /// what every proposal written before the librarian is.
        case add
        /// Replace the named facts with ``proposedContent`` as one. The source
        /// bodies are archived rather than destroyed — the merged text is a
        /// summary, and the originals are what it was summarised from.
        case merge(topics: [String])
        /// Remove the named fact and its body. Irreversible, which is why it
        /// carries ``evidence`` and why a human has to press it.
        case delete(topic: String)
        /// Take the named fact out of the index, keeping its body under
        /// `memory/archive/`. It stops riding into prompts and stops being
        /// recalled; nothing is lost.
        case archive(topic: String)

        /// The word the UI puts on the card.
        package var label: String {
            switch self {
            case .add: return "Add"
            case .merge: return "Merge"
            case .delete: return "Delete"
            case .archive: return "Archive"
            }
        }

        /// The facts this operation acts on, empty for `.add`.
        package var topics: [String] {
            switch self {
            case .add: return []
            case .merge(let topics): return topics
            case .delete(let topic), .archive(let topic): return [topic]
            }
        }

        /// Whether editing the proposed text changes what approving does.
        /// It does not for a deletion or an archival: their text is the reason,
        /// and offering an editor for it would suggest otherwise.
        package var isContentMeaningful: Bool {
            switch self {
            case .add, .merge: return true
            case .delete, .archive: return false
            }
        }
    }

    package init(
        agentID: String,
        proposedContent: String,
        operation: Operation = .add,
        source: Source = .agent,
        rationale: String? = nil,
        evidence: String? = nil
    ) {
        self.id = UUID().uuidString
        self.agentID = agentID
        self.timestamp = Date()
        self.proposedContent = proposedContent
        self.approvedContent = nil
        self.status = .pending
        self.operation = operation
        self.source = source
        self.rationale = rationale
        self.evidence = evidence
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, agentID, timestamp, proposedContent, approvedContent, status, operation, source, rationale, evidence
    }

    /// Decoded with defaults for everything the librarian added, so a proposal
    /// written by an older build still loads — and loads as what it was, an
    /// agent's request to add a fact, rather than failing to decode and
    /// disappearing from the pending list.
    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        agentID = try container.decode(String.self, forKey: .agentID)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        proposedContent = try container.decode(String.self, forKey: .proposedContent)
        approvedContent = try container.decodeIfPresent(String.self, forKey: .approvedContent)
        status = try container.decode(Status.self, forKey: .status)
        operation = try container.decodeIfPresent(Operation.self, forKey: .operation) ?? .add
        source = try container.decodeIfPresent(Source.self, forKey: .source) ?? .agent
        rationale = try container.decodeIfPresent(String.self, forKey: .rationale)
        evidence = try container.decodeIfPresent(String.self, forKey: .evidence)
    }
}
