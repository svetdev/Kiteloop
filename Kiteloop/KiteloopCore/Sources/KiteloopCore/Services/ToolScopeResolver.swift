// The Arch-Mage's resolution engine: composing layered wards into the final incantation envelope.
import Foundation

package enum ToolScopeResolver {
    package static func resolve(profile: ProfileToolScope, layers: [LayerToolScope]) -> ResolvedToolScope {
        var effective = profile.allowed
        var allDenied = profile.denied

        var contributions: [ScopeContribution] = [
            ScopeContribution(
                source: .profile,
                allowed: profile.allowed,
                denied: profile.denied,
                policyVersion: profile.policyVersion
            )
        ]

        for layer in layers {
            allDenied.formUnion(layer.denied)

            if let layerAllowed = layer.allowed {
                effective.formIntersection(layerAllowed)
            }

            contributions.append(ScopeContribution(
                source: layer.source,
                allowed: layer.allowed,
                denied: layer.denied,
                policyVersion: layer.policyVersion
            ))
        }

        // Deny-precedence: banishments always override allowances.
        effective.subtract(allDenied)

        return ResolvedToolScope(
            effective: effective,
            base: profile.allowed,
            denied: allDenied,
            contributions: contributions
        )
    }
}
