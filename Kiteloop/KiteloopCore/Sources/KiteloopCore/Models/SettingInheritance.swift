import Foundation

/// Where a setting's effective value came from, widest scope first. Every
/// setting in the app belongs to the machine, to a project or to an agent, and
/// each narrower scope inherits from the wider one; the built-in is the floor
/// under all three.
package enum SettingScope: String, Sendable, Equatable, CaseIterable {
    case builtIn = "built-in"
    case app
    case project
    case agent
}

/// A setting as it takes effect at some scope: the value, and the scope that
/// set it. The question a settings page has to answer is not "where is the
/// setting" but "which one wins", and this is the answer as a value.
package struct ResolvedSetting<Value: Sendable & Equatable>: Sendable, Equatable {
    package let value: Value
    package let scope: SettingScope

    package init(value: Value, scope: SettingScope) {
        self.value = value
        self.scope = scope
    }
}

/// The one rule for inherited settings, so every page states it the same way:
/// the narrowest explicit value wins, and the built-in is what remains when
/// nothing is explicit. Pure, so a page's label is a function of the stored
/// values and nothing else.
package enum SettingInheritance {

    /// The narrowest explicit value, and its scope. Pass only the scopes the
    /// caller stands at or above — a project page passes `app` and nothing
    /// narrower, since the project's own value is what its picker edits.
    package static func resolve<Value: Sendable & Equatable>(
        builtIn: Value,
        app: Value? = nil,
        project: Value? = nil,
        agent: Value? = nil
    ) -> ResolvedSetting<Value> {
        if let agent { return ResolvedSetting(value: agent, scope: .agent) }
        if let project { return ResolvedSetting(value: project, scope: .project) }
        if let app { return ResolvedSetting(value: app, scope: .app) }
        return ResolvedSetting(value: builtIn, scope: .builtIn)
    }

    /// A stored string as an explicit value: nil when empty, because every
    /// form here stores "" for "not set" and an empty string must not win the
    /// resolution as if somebody had chosen it.
    package static func present(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// What a picker's Default entry says: the value it would inherit and the
    /// scope it comes from — "Default (app · Fable 5.1)".
    package static func defaultLabel<Value>(
        _ resolved: ResolvedSetting<Value>,
        describe: (Value) -> String
    ) -> String {
        "Default (\(resolved.scope.rawValue) · \(describe(resolved.value)))"
    }

    /// What a value set at a wider scope reads as on a narrower page —
    /// "Project default: Fable 5.1 (app)" — where the narrower page holds its
    /// own concrete value rather than a Default entry.
    package static func inheritedNote<Value>(
        _ resolved: ResolvedSetting<Value>,
        prefix: String,
        describe: (Value) -> String
    ) -> String {
        "\(prefix): \(describe(resolved.value)) (\(resolved.scope.rawValue))"
    }
}

/// The names the pickers show for the raw values the config files store, kept
/// in one place so a label on one page cannot spell a value differently from
/// the picker on another.
package enum SettingNames {

    package static func permissionMode(_ raw: String) -> String {
        switch raw {
        case "auto": return "Auto"
        case "acceptEdits": return "Accept Edits"
        case "plan": return "Plan (read-only)"
        case "default": return "Ask (before edits and commands)"
        case "dontAsk": return "Don't Ask (refuse what would ask)"
        case "bypassPermissions": return "Bypass All"
        default: return raw
        }
    }

    /// The effort levels, with "" — the stored spelling of "let the agent
    /// decide" — named as such.
    package static func effort(_ raw: String) -> String {
        switch raw {
        case "": return "agent's own"
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh": return "Extra High"
        case "max": return "Max"
        default: return raw
        }
    }
}
