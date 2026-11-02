import Foundation

package struct Span: Codable, Identifiable, Sendable {
    package let traceID: String
    package let spanID: String
    package let parentSpanID: String?
    package let name: String
    package let spanType: KiteloopSpanType
    package let agentID: String?
    package let startTime: Date
    package var endTime: Date?
    package var status: SpanStatus
    package var attributes: [String: AttributeValue]
    package var events: [SpanEvent]
    package var links: [SpanLink]

    package var id: String { spanID }

    package var duration: TimeInterval? {
        guard let end = endTime else { return nil }
        return end.timeIntervalSince(startTime)
    }

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(traceID: String, spanID: String, parentSpanID: String?, name: String, spanType: KiteloopSpanType, agentID: String?, startTime: Date, endTime: Date? = nil, status: SpanStatus, attributes: [String: AttributeValue], events: [SpanEvent], links: [SpanLink]) {
        self.traceID = traceID
        self.spanID = spanID
        self.parentSpanID = parentSpanID
        self.name = name
        self.spanType = spanType
        self.agentID = agentID
        self.startTime = startTime
        self.endTime = endTime
        self.status = status
        self.attributes = attributes
        self.events = events
        self.links = links
    }
}

package enum KiteloopSpanType: String, Codable, Sendable {
    case workflowExecution
    case nodeExecution
    case session
    case turn
    case toolCall
}

package struct SpanEvent: Codable, Sendable {
    package let name: String
    package let timestamp: Date
    package let attributes: [String: AttributeValue]

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(name: String, timestamp: Date, attributes: [String: AttributeValue]) {
        self.name = name
        self.timestamp = timestamp
        self.attributes = attributes
    }
}

package struct SpanLink: Codable, Sendable {
    package let traceID: String
    package let spanID: String
    package let attributes: [String: AttributeValue]

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(traceID: String, spanID: String, attributes: [String: AttributeValue]) {
        self.traceID = traceID
        self.spanID = spanID
        self.attributes = attributes
    }
}

package enum SpanStatus: String, Codable, Sendable {
    case unset
    case ok
    case error
}

package enum AttributeValue: Codable, Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    package enum CodingKeys: String, CodingKey {
        case type, value
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let v):
            try container.encode("string", forKey: .type)
            try container.encode(v, forKey: .value)
        case .int(let v):
            try container.encode("int", forKey: .type)
            try container.encode(v, forKey: .value)
        case .double(let v):
            try container.encode("double", forKey: .type)
            try container.encode(v, forKey: .value)
        case .bool(let v):
            try container.encode("bool", forKey: .type)
            try container.encode(v, forKey: .value)
        }
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "string":
            self = .string(try container.decode(String.self, forKey: .value))
        case "int":
            self = .int(try container.decode(Int.self, forKey: .value))
        case "double":
            self = .double(try container.decode(Double.self, forKey: .value))
        case "bool":
            self = .bool(try container.decode(Bool.self, forKey: .value))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown AttributeValue type: \(type)"
            )
        }
    }
}
