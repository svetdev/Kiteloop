import KiteloopCore
import SwiftUI

/// What this project's agents were told to remember from a permission card's
/// "Always allow…", each with a button that takes it back — so the next call
/// like it asks again. The list is the CLI's own
/// (`RememberedPermissions`); it is read when the page opens.
struct RememberedPermissionsList: View {
    let projectRoot: URL
    @State private var rules: [String] = []
    @State private var problem: String?

    var body: some View {
        Group {
            if rules.isEmpty {
                Text("Nothing remembered yet. Choosing “Always allow…” on a permission card in a chat adds a rule here.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            ForEach(rules, id: \.self) { rule in
                HStack {
                    Text(rule)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                    Spacer()
                    Button("Remove") { remove(rule) }
                        .accessibilityIdentifier("remembered-permission-remove")
                }
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear { rules = RememberedPermissions.load(projectRoot: projectRoot) }
    }

    private func remove(_ rule: String) {
        do {
            rules = try RememberedPermissions.remove(rule, projectRoot: projectRoot)
            problem = nil
        } catch {
            problem = "Could not update the project's remembered permissions: \(error.localizedDescription)"
        }
    }
}
