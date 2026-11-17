import KiteloopCore
import SwiftUI

/// The confirmation a person answers before a pack is installed into a
/// project: what it would add, what each agent and connector would be allowed
/// to do, what needs their eye and what is refused (`PackInstallPlan`).
///
/// Nothing is written until Install; a pack with a refused entry cannot be
/// installed at all.
struct PackInstallSheet: View {
    let folder: URL
    /// Reads the pack against the project; writes nothing.
    let makePlan: () throws -> PackInstallPlan
    let install: (PackInstallPlan) throws -> Void
    let onClose: () -> Void

    @State private var plan: PackInstallPlan?
    /// Why the folder could not be read as a pack, or why the install failed.
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ScrollView {
                Text(plan?.account ?? "")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 360)
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            footer
        }
        .padding(16)
        .frame(width: 560)
        .accessibilityIdentifier("pack-install-sheet")
        .onAppear(perform: read)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Install Pack")
                .font(.headline)
            Text(folder.path(percentEncoded: false))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Spacer()
            Button("Cancel", role: .cancel, action: onClose)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("pack-install-cancel")
            Button("Install", action: confirm)
                .buttonStyle(.borderedProminent)
                .disabled(plan?.canInstall != true)
                .accessibilityIdentifier("pack-install-confirm")
        }
    }

    private func read() {
        do {
            plan = try makePlan()
        } catch {
            failure = "This folder cannot be installed as a pack: \(error.localizedDescription)"
        }
    }

    private func confirm() {
        guard let plan else { return }
        do {
            try install(plan)
            onClose()
        } catch {
            failure = (error as? Routine.Refusal)?.reason ?? error.localizedDescription
            // What was read no longer stands: show the pack as it reads now.
            self.plan = try? makePlan()
        }
    }
}

/// Puts the confirmation up over a project's window when File > Install
/// Pack… has offered that project a pack folder.
struct PackInstallSheetPresenter: ViewModifier {
    let session: ProjectSession?
    let routines: RoutineRunner?
    let globalConfigStore: GlobalConfigStore

    private var offered: Binding<OfferedPack?> {
        Binding(get: { session?.offeredPack }, set: { session?.offeredPack = $0 })
    }

    func body(content: Content) -> some View {
        content.sheet(item: offered) { pack in
            if let session {
                PackInstallSheet(
                    folder: pack.folder,
                    makePlan: {
                        try session.packInstallPlan(folder: pack.folder, routines: routines,
                                                    globalConfig: globalConfigStore)
                    },
                    install: { try session.installPack($0, routines: routines, globalConfig: globalConfigStore) },
                    onClose: { session.offeredPack = nil })
            }
        }
    }
}
