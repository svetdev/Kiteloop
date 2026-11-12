import Foundation

/// The rules a project's agents were told to remember from a permission
/// card's "Always allow…" — kept by the CLI itself, in the project's
/// `.claude/settings.local.json` under `permissions.allow`, where every later
/// session in the project reads them. This reads that list and takes a rule
/// back out of it; adding one is the CLI's doing, on an answered card.
package enum RememberedPermissions {

    /// The file the CLI keeps a project's remembered rules in.
    package static func fileURL(projectRoot: URL) -> URL {
        projectRoot.appending(path: ".claude").appending(path: "settings.local.json")
    }

    /// The rules in `contents`, in the file's order — `Bash(make test)`,
    /// `Read(//tmp/**)`. Empty for no file, a file that is not a JSON object,
    /// or one with no allow list.
    package static func rules(in contents: Data?) -> [String] {
        (permissions(in: contents)["allow"] as? [String]) ?? []
    }

    /// `contents` with `rule` gone from the allow list and everything else
    /// in the file as it was; nil when the file is not a JSON object or holds
    /// no such rule, so nothing is rewritten for nothing.
    package static func removing(_ rule: String, from contents: Data?) -> Data? {
        guard var settings = object(in: contents) else { return nil }
        var granted = permissions(in: contents)
        var allow = rules(in: contents)
        guard let index = allow.firstIndex(of: rule) else { return nil }
        allow.remove(at: index)
        granted["allow"] = allow
        settings["permissions"] = granted
        return try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
    }

    /// The rules the project at `projectRoot` holds now.
    package static func load(projectRoot: URL) -> [String] {
        rules(in: try? Data(contentsOf: fileURL(projectRoot: projectRoot)))
    }

    /// Takes `rule` out of the project's file, when it holds it, and answers
    /// the rules left. Throws only when the rewritten file cannot be saved.
    @discardableResult
    package static func remove(_ rule: String, projectRoot: URL) throws -> [String] {
        let url = fileURL(projectRoot: projectRoot)
        if let rewritten = removing(rule, from: try? Data(contentsOf: url)) {
            try rewritten.write(to: url, options: .atomic)
        }
        return load(projectRoot: projectRoot)
    }

    private static func object(in contents: Data?) -> [String: Any]? {
        guard let contents else { return nil }
        return try? JSONSerialization.jsonObject(with: contents) as? [String: Any]
    }

    private static func permissions(in contents: Data?) -> [String: Any] {
        (object(in: contents)?["permissions"] as? [String: Any]) ?? [:]
    }
}
