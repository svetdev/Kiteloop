// Arcane instrument for scoping which incantations a Familiar may wield.
import Foundation

/// The maximum envelope of tools a Familiar is permitted to invoke, as declared by its profile.
package struct ProfileToolScope: Codable, Sendable, Equatable {
    /// Explicit allow-set — the outer ward defining reachable incantations.
    package let allowed: Set<String>
    /// Explicit deny-set — runes that override any allowance; deny takes precedence.
    package let denied: Set<String>
    /// Version sigil for the policy grimoire entry.
    package let policyVersion: String

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(allowed: Set<String>, denied: Set<String>, policyVersion: String) {
        self.allowed = allowed
        self.denied = denied
        self.policyVersion = policyVersion
    }
}

/// A layer-level scope overlay applied atop the profile envelope.
/// `allowed == nil` acts as identity — the layer imposes no additional restriction on allowed tools.
/// `allowed == []` blocks all tools for this layer.
package struct LayerToolScope: Codable, Sendable, Equatable {
    /// Intersection mask. nil = no restriction (identity). Empty set = block all.
    package let allowed: Set<String>?
    /// Deny override runes for this layer — always takes precedence.
    package let denied: Set<String>
    /// Version sigil for the policy grimoire entry.
    package let policyVersion: String
    /// The arcane origin of this layer scope.
    package let source: ToolScopeSource

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(allowed: Set<String>?, denied: Set<String>, policyVersion: String, source: ToolScopeSource) {
        self.allowed = allowed
        self.denied = denied
        self.policyVersion = policyVersion
        self.source = source
    }
}

/// Identifies the origin of a scope contribution along the Ley Line.
package enum ToolScopeSource: Codable, Sendable, Equatable {
    /// Derived directly from the Familiar's profile ward.
    case profile
    /// Injected by a task-level hint rune.
    case taskHint(taskID: String)
    /// Bound to a specific node in a workflow graph summoning.
    case workflowNode(graphID: String, nodeID: String)
}

/// Records one contributor's provenance in the final scope resolution.
package struct ScopeContribution: Codable, Sendable, Equatable {
    /// Origin of this contribution.
    package let source: ToolScopeSource
    /// Allowed set from this contributor; nil = identity (no additional restriction).
    package let allowed: Set<String>?
    /// Denied set from this contributor.
    package let denied: Set<String>
    /// Policy version for this contributor's grimoire entry.
    package let policyVersion: String

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(source: ToolScopeSource, allowed: Set<String>?, denied: Set<String>, policyVersion: String) {
        self.source = source
        self.allowed = allowed
        self.denied = denied
        self.policyVersion = policyVersion
    }
}

/// The final resolved tool scope — the product of all layers and deny-precedence resolution.
package struct ResolvedToolScope: Codable, Sendable, Equatable {
    /// The effective set of tools the Familiar may wield (base minus denied).
    package let effective: Set<String>
    /// The base set after all allowed intersections, before deny application.
    package let base: Set<String>
    /// The union of all denied runes across contributions.
    package let denied: Set<String>
    /// Ordered provenance trail of every scope contributor.
    package let contributions: [ScopeContribution]

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(effective: Set<String>, base: Set<String>, denied: Set<String>, contributions: [ScopeContribution]) {
        self.effective = effective
        self.base = base
        self.denied = denied
        self.contributions = contributions
    }
}
