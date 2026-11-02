import Foundation
import KiteloopCore

/// The Grimoire Records for task specialist templates — persists the agent catalog
/// to ~/.kiteloop/agent-catalog.json and seeds from the hardcoded defaults on first launch.
@Observable
@MainActor
class AgentCatalogStore {
    private let storageURL: URL
    private let reporter: StoreProblemReporter
    private(set) var templates: [AgentTemplate] = []
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var suppressNextReload = false

    static let defaultURL: URL = {
        let home = KiteloopHome.url
        let dir = home.appending(path: ".kiteloop")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "agent-catalog.json")
    }()

    /// The name this store reports under. A human reads it in a notification
    /// title, and it is half the dedup key, so it is spelled once.
    static let storeName = "Agent catalog"

    init(storageURL: URL? = nil, reporter: StoreProblemReporter = .shared) {
        self.storageURL = storageURL ?? Self.defaultURL
        self.reporter = reporter
        loadKeepingAnUnreadableFile()
        if templates.isEmpty {
            seedDefaults()
        }
        startWatching()
    }

    // Cleanup handled by DispatchSource's cancel handler

    /// Find a template by its handle (lowercased name, spaces become dashes).
    func find(handle: String) -> AgentTemplate? {
        let normalized = handle.lowercased()
        return templates.first { templateHandle(for: $0) == normalized }
    }

    /// Derive the lookup handle for a template.
    func templateHandle(for template: AgentTemplate) -> String {
        template.name.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    /// All templates whose handle or group starts with the given prefix — useful for autocomplete.
    func search(prefix: String) -> [AgentTemplate] {
        let lower = prefix.lowercased()
        return templates.filter {
            templateHandle(for: $0).hasPrefix(lower)
            || ($0.group?.lowercased().hasPrefix(lower) ?? false)
        }
    }

    func add(_ template: AgentTemplate) {
        guard !templates.contains(where: { $0.id == template.id }) else { return }
        templates.append(template)
        save()
    }

    func update(_ template: AgentTemplate) {
        guard let idx = templates.firstIndex(where: { $0.id == template.id }) else { return }
        templates[idx] = template
        save()
    }

    func remove(id: String) {
        templates.removeAll { $0.id == id }
        save()
    }

    // MARK: - Private

    private func seedDefaults() {
        templates = Array(AgentTemplate.catalog.values).sorted { $0.name < $1.name }
        save()
    }

    /// The launch read, which distinguishes the two cases one `try?` used to
    /// collapse.
    ///
    /// No file at all is the ordinary first-launch state: nothing is reported,
    /// `templates` stays empty, and `init` seeds. A file that is *there* but
    /// will not decode is a different thing entirely — it used to read the same
    /// way, and the `save()` inside `seedDefaults()` then wrote
    /// `AgentTemplate.catalog` straight over it, so every template the user had
    /// added was gone before the window opened with nothing said. The refusal
    /// now moves those bytes aside first and reports where they went, and only
    /// then does the seed land on a path nothing occupies.
    private func loadKeepingAnUnreadableFile() {
        guard let decoded = QuarantiningJSONFile.load([AgentTemplate].self,
                                                      from: storageURL,
                                                      store: Self.storeName,
                                                      reporter: reporter) else {
            return
        }
        templates = decoded
    }

    /// The watcher's read, for a write that came from outside the app.
    ///
    /// Deliberately *not* quarantining, unlike the launch read: a file being
    /// edited by hand is undecodable for as long as it takes to type the rest of
    /// it, and moving it out from under the editor is exactly the loss the
    /// launch read exists to prevent. Nothing here overwrites it either — the
    /// only writer is `save()`, which runs when the app changes a template — so
    /// leaving both the file and `templates` as they are until a readable write
    /// arrives costs nothing.
    private func reloadAfterExternalWrite() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([AgentTemplate].self, from: data) else {
            return
        }
        templates = decoded
    }

    private func save() {
        suppressNextReload = true
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(templates) else { return }
        // Durably, not just `.atomic` — an unclean shutdown must never leave a
        // truncated catalog behind, because the next launch would read it as
        // empty and seed the defaults over it.
        do {
            try AtomicFileWriter.write(data, to: storageURL)
        } catch {
            // `add`/`update`/`remove` all save, so a catalog that has stopped
            // saving looks exactly like one nobody changed: the template
            // reverts on the next launch and nothing anywhere said why.
            reporter.report(store: Self.storeName, operation: .write, url: storageURL, error: error)
        }
    }

    // MARK: - File Watching

    private func startWatching() {
        let path = storageURL.path(percentEncoded: false)
        fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                if self.suppressNextReload {
                    self.suppressNextReload = false
                    return
                }
                self.reloadAfterExternalWrite()
            }
        }

        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fileDescriptor >= 0 {
                close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
        }

        source.resume()
        fileWatcher = source
    }
}
