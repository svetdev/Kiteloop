import Foundation

// MARK: - Intent

package enum A2AIntent: String, Codable, Sendable {
    case consult
    case delegate
    case notify
    case review
    case escalate
}

// MARK: - Payload

package enum A2APayload: Codable, Sendable {
    case text(String)
    case structured(StructuredRequest)
    case artifact(ArtifactPayload)

    package struct StructuredRequest: Codable, Sendable {
        package let topic: String
        package let body: String
        package let context: [String: AnyCodable]?
        package let constraints: [String]?
        package let referencedFiles: [String]?
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(topic: String, body: String, context: [String: AnyCodable]?, constraints: [String]?, referencedFiles: [String]?) {
            self.topic = topic
            self.body = body
            self.context = context
            self.constraints = constraints
            self.referencedFiles = referencedFiles
        }
    }

    package struct ArtifactPayload: Codable, Sendable {
        package let description: String
        package let content: String
        package let contentType: String
        package let action: ArtifactAction

        package enum ArtifactAction: String, Codable, Sendable {
            case review, apply, transform, store
        }
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(description: String, content: String, contentType: String, action: ArtifactAction) {
            self.description = description
            self.content = content
            self.contentType = contentType
            self.action = action
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, value
    }

    private enum PayloadType: String, Codable {
        case text, structured, artifact
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let s):
            try container.encode(PayloadType.text, forKey: .type)
            try container.encode(s, forKey: .value)
        case .structured(let r):
            try container.encode(PayloadType.structured, forKey: .type)
            try container.encode(r, forKey: .value)
        case .artifact(let a):
            try container.encode(PayloadType.artifact, forKey: .type)
            try container.encode(a, forKey: .value)
        }
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(PayloadType.self, forKey: .type)
        switch type {
        case .text:
            self = .text(try container.decode(String.self, forKey: .value))
        case .structured:
            self = .structured(try container.decode(StructuredRequest.self, forKey: .value))
        case .artifact:
            self = .artifact(try container.decode(ArtifactPayload.self, forKey: .value))
        }
    }
}

// MARK: - Metadata

package struct A2AMetadata: Codable, Sendable {
    package let traceID: String
    package let spanID: String
    package let parentSpanID: String?
    package let conversationID: String?
    package var timing: Timing?

    package struct Timing: Codable, Sendable {
        package let sentAt: Date
        package var receivedAt: Date?
        package var completedAt: Date?
        package var processingDuration: TimeInterval?
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(sentAt: Date, receivedAt: Date? = nil, completedAt: Date? = nil, processingDuration: TimeInterval? = nil) {
            self.sentAt = sentAt
            self.receivedAt = receivedAt
            self.completedAt = completedAt
            self.processingDuration = processingDuration
        }
    }

    package init(
        traceID: String = OTelIDs.newTraceID(),
        spanID: String = OTelIDs.newSpanID(),
        parentSpanID: String? = nil,
        conversationID: String? = nil,
        timing: Timing? = nil
    ) {
        self.traceID = traceID
        self.spanID = spanID
        self.parentSpanID = parentSpanID
        self.conversationID = conversationID
        self.timing = timing
    }
}

// MARK: - Message Envelope

package struct A2AMessage: Codable, Identifiable, Sendable {
    package let id: String
    package let intent: A2AIntent
    package let sender: AgentRef
    package let target: AgentRef
    package let payload: A2APayload
    package let metadata: A2AMetadata
    package let createdAt: Date

    package struct AgentRef: Codable, Sendable {
        package let id: String
        package let name: String
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    package init(
        intent: A2AIntent,
        sender: AgentRef,
        target: AgentRef,
        payload: A2APayload,
        metadata: A2AMetadata? = nil,
        createdAt: Date = Date()
    ) {
        self.id = UUID().uuidString
        self.intent = intent
        self.sender = sender
        self.target = target
        self.payload = payload
        self.metadata = metadata ?? A2AMetadata()
        self.createdAt = createdAt
    }
}

// MARK: - Response

package struct A2AResponse: Codable, Identifiable, Sendable {
    package let id: String
    package let messageID: String
    package let status: ResponseStatus
    package let payload: ResponsePayload
    package let metadata: A2AMetadata
    package let createdAt: Date

    package enum ResponseStatus: String, Codable, Sendable {
        case success, declined, partial, failed
    }

    package enum ResponsePayload: Codable, Sendable {
        case text(String)
        case structured(StructuredResult)
        case artifact(A2APayload.ArtifactPayload)
        case reviewVerdict(ReviewVerdict)

        package struct StructuredResult: Codable, Sendable {
            package let summary: String
            package let detail: String?
            package let data: [String: AnyCodable]?
            package let confidence: Double?
            package let suggestions: [String]?
        
            /// The memberwise init, spelled out: a `package` type's synthesised one is
            /// internal to the package, and the app constructs this.
            package init(summary: String, detail: String?, data: [String: AnyCodable]?, confidence: Double?, suggestions: [String]?) {
                self.summary = summary
                self.detail = detail
                self.data = data
                self.confidence = confidence
                self.suggestions = suggestions
            }
        }

        package struct ReviewVerdict: Codable, Sendable {
            package let passed: Bool
            package let feedback: String
            package let issues: [ReviewIssue]?

            package struct ReviewIssue: Codable, Sendable {
                package let severity: String
                package let description: String
                package let location: String?
            
                /// The memberwise init, spelled out: a `package` type's synthesised one is
                /// internal to the package, and the app constructs this.
                package init(severity: String, description: String, location: String?) {
                    self.severity = severity
                    self.description = description
                    self.location = location
                }
            }
        
            /// The memberwise init, spelled out: a `package` type's synthesised one is
            /// internal to the package, and the app constructs this.
            package init(passed: Bool, feedback: String, issues: [ReviewIssue]?) {
                self.passed = passed
                self.feedback = feedback
                self.issues = issues
            }
        }

        private enum CodingKeys: String, CodingKey {
            case type, value
        }

        private enum PayloadType: String, Codable {
            case text, structured, artifact, reviewVerdict
        }

        package func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let s):
                try container.encode(PayloadType.text, forKey: .type)
                try container.encode(s, forKey: .value)
            case .structured(let r):
                try container.encode(PayloadType.structured, forKey: .type)
                try container.encode(r, forKey: .value)
            case .artifact(let a):
                try container.encode(PayloadType.artifact, forKey: .type)
                try container.encode(a, forKey: .value)
            case .reviewVerdict(let v):
                try container.encode(PayloadType.reviewVerdict, forKey: .type)
                try container.encode(v, forKey: .value)
            }
        }

        package init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(PayloadType.self, forKey: .type)
            switch type {
            case .text:
                self = .text(try container.decode(String.self, forKey: .value))
            case .structured:
                self = .structured(try container.decode(StructuredResult.self, forKey: .value))
            case .artifact:
                self = .artifact(try container.decode(A2APayload.ArtifactPayload.self, forKey: .value))
            case .reviewVerdict:
                self = .reviewVerdict(try container.decode(ReviewVerdict.self, forKey: .value))
            }
        }
    }

    package init(
        messageID: String,
        status: ResponseStatus,
        payload: ResponsePayload,
        metadata: A2AMetadata? = nil,
        createdAt: Date = Date()
    ) {
        self.id = UUID().uuidString
        self.messageID = messageID
        self.status = status
        self.payload = payload
        self.metadata = metadata ?? A2AMetadata()
        self.createdAt = createdAt
    }
}
