import Foundation

package struct WorkflowEdge: Codable, Sendable, Equatable {
    package let from: String
    package let to: String
    package let condition: EdgeCondition
    package var priority: Int
    package var carryForwardSource: CarryForwardSource

    package init(
        from: String,
        to: String,
        condition: EdgeCondition,
        priority: Int = 0,
        carryForwardSource: CarryForwardSource = .nodeOutput
    ) {
        self.from = from
        self.to = to
        self.condition = condition
        self.priority = priority
        self.carryForwardSource = carryForwardSource
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = try c.decode(String.self, forKey: .from)
        to = try c.decode(String.self, forKey: .to)
        condition = try c.decode(EdgeCondition.self, forKey: .condition)
        priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 0

        if let explicit = try c.decodeIfPresent(CarryForwardSource.self, forKey: .carryForwardSource) {
            carryForwardSource = explicit
        } else {
            carryForwardSource = CarryForwardSource.defaultFor(condition: condition)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case from, to, condition, priority, carryForwardSource
    }
}

package enum CarryForwardSource: String, Codable, Sendable, Equatable {
    case nodeOutput
    case eventPayload
    case approvalPayload

    package static func defaultFor(condition: EdgeCondition) -> CarryForwardSource {
        switch condition {
        case .eventType:
            return .eventPayload
        case .outputMatch, .always:
            return .nodeOutput
        case .humanApproval:
            return .approvalPayload
        case .allOf, .anyOf:
            return .nodeOutput
        }
    }
}

package indirect enum EdgeCondition: Codable, Sendable, Equatable {
    case eventType(String)
    case outputMatch(key: String, value: String)
    case always
    case humanApproval(question: String, deniedEdge: String?)
    case allOf([EdgeCondition])
    case anyOf([EdgeCondition])

    private enum ConditionType: String, Codable {
        case eventType, outputMatch, always, humanApproval, allOf, anyOf
    }

    private enum CodingKeys: String, CodingKey {
        case type, value, key, question, deniedEdge, conditions
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .eventType(let v):
            try container.encode(ConditionType.eventType, forKey: .type)
            try container.encode(v, forKey: .value)
        case .outputMatch(let k, let v):
            try container.encode(ConditionType.outputMatch, forKey: .type)
            try container.encode(k, forKey: .key)
            try container.encode(v, forKey: .value)
        case .always:
            try container.encode(ConditionType.always, forKey: .type)
        case .humanApproval(let q, let denied):
            try container.encode(ConditionType.humanApproval, forKey: .type)
            try container.encode(q, forKey: .question)
            try container.encodeIfPresent(denied, forKey: .deniedEdge)
        case .allOf(let conds):
            try container.encode(ConditionType.allOf, forKey: .type)
            try container.encode(conds, forKey: .conditions)
        case .anyOf(let conds):
            try container.encode(ConditionType.anyOf, forKey: .type)
            try container.encode(conds, forKey: .conditions)
        }
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ConditionType.self, forKey: .type)
        switch type {
        case .eventType:
            let v = try container.decode(String.self, forKey: .value)
            self = .eventType(v)
        case .outputMatch:
            let k = try container.decode(String.self, forKey: .key)
            let v = try container.decode(String.self, forKey: .value)
            self = .outputMatch(key: k, value: v)
        case .always:
            self = .always
        case .humanApproval:
            let q = try container.decode(String.self, forKey: .question)
            let denied = try container.decodeIfPresent(String.self, forKey: .deniedEdge)
            self = .humanApproval(question: q, deniedEdge: denied)
        case .allOf:
            let conds = try container.decode([EdgeCondition].self, forKey: .conditions)
            self = .allOf(conds)
        case .anyOf:
            let conds = try container.decode([EdgeCondition].self, forKey: .conditions)
            self = .anyOf(conds)
        }
    }
}
