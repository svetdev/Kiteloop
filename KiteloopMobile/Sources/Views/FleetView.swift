import SwiftUI

/// The fleet as one thing: whether it is taking work and the one lever that
/// changes that, the Planner's passes and the shared budget, and this phone's
/// connection. Every lever shows its state and offers the one move away from
/// it — never a pair of buttons for both directions. The line at the top says
/// whether the screen is fresh, refreshing, or failed, and what to do.
struct FleetView: View {
    @Bindable var connection: ConnectionStore
    @State private var model = LeversViewModel()
    @State private var ceiling = 24
    @State private var pairingAnother = false

    private var client: ControlClient { ControlClient(baseURL: connection.baseURL, token: connection.token) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                RefreshStatusBar(state: model.freshness) { Task { await model.refresh(client) } }
                Divider()
                Form {
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
                    }
                    if let note = model.confirmation {
                        Label(note, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
                    }
                    fleetSection
                    usageSection
                    plannerSection
                    macsSection
                }
                .refreshable { await model.refresh(client) }
            }
            .navigationTitle("Fleet")
            .sheet(isPresented: $pairingAnother) {
                ConnectView(connection: connection, onPaired: { pairingAnother = false })
            }
            .task {
                while !Task.isCancelled {
                    await model.refresh(client)
                    if let max = model.refill?.budget?.maxPasses, ceiling == 24 { ceiling = max }
                    try? await Task.sleep(for: .seconds(15))
                }
            }
        }
    }

    /// Every paired Mac: tap one to switch to it, swipe to forget it.
    private var macsSection: some View {
        Section {
            ForEach(connection.macs) { mac in
                Button {
                    connection.select(mac.id)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mac.name).foregroundStyle(.primary)
                            Text(mac.baseURL).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if mac.id == connection.currentID {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
                .accessibilityIdentifier("mac-\(mac.name)")
            }
            .onDelete { offsets in
                for id in offsets.map({ connection.macs[$0].id }) { connection.remove(id) }
            }
            Button("Pair another Mac") { pairingAnother = true }
        } header: {
            Text("Macs")
        } footer: {
            Text("Swipe a Mac to forget it and its token.")
        }
    }

    /// Taking work, or quiesced — and the one lever away from it.
    private var fleetSection: some View {
        Section {
            let fleet = model.fleet
            let quiesced = fleet?.quiesced == true
            HStack(spacing: 10) {
                Image(systemName: quiesced ? "pause.circle.fill" : "circle.hexagongrid.fill")
                    .font(.title2)
                    .foregroundStyle(quiesced ? .orange : .green)
                    .symbolEffect(.variableColor.iterative.reversing, isActive: (fleet?.running ?? 0) > 0)
                VStack(alignment: .leading, spacing: 3) {
                    Text(quiesced ? "Quiesced" : "Taking work").font(.headline)
                    Text(fleet?.summary ?? "").font(.caption).foregroundStyle(.secondary)
                }
            }
            Button {
                Task { await model.fleet(client, resume: quiesced) }
            } label: {
                Text(quiesced ? "Resume the fleet" : "Quiesce — stop taking new work").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(quiesced ? .green : .orange)
        }
    }

    /// How close the agents are to their rate limit, and where the last
    /// day's spend went, project by project.
    private var usageSection: some View {
        Section("Usage") {
            let limit = model.usage?.rateLimit
            Label(UsageReply.rateLimitLine(limit),
                  systemImage: limit?.isWarning == true ? "exclamationmark.triangle.fill" : "gauge.with.dots.needle.33percent")
                .font(.callout)
                .foregroundStyle(limit?.isWarning == true ? .orange : .primary)
            if let spend = model.usage?.spend {
                ForEach(spend.projects ?? [], id: \.self) { row in
                    LabeledContent(row.project, value: String(format: "$%.2f", row.spendUSD ?? 0))
                }
                LabeledContent("Last \(spend.hours ?? 24) h, all projects", value: String(format: "$%.2f", spend.totalUSD ?? 0))
                    .font(.callout.weight(.semibold))
            }
        }
    }

    private var plannerSection: some View {
        Section("Planner") {
            if let budget = model.refill?.budget {
                LabeledContent("Passes today", value: "\(budget.passesUsed ?? 0) of \(budget.maxPasses.map(String.init) ?? "∞")")
                if let max = budget.maxPasses, max > 0 {
                    ProgressView(value: min(Double(budget.passesUsed ?? 0) / Double(max), 1))
                }
            }
            Stepper("Ceiling: \(ceiling)/day", value: $ceiling, in: 1...96)
            if ceiling != (model.refill?.budget?.maxPasses ?? ceiling) {
                Button("Apply ceiling") { Task { await model.setPassCeiling(client, ceiling) } }
            }
            runsAtOnce
            if let pool = model.scheduling?.budget {
                LabeledContent("Daily budget (shared)",
                               value: String(format: "$%.2f of %@", pool.spentTodayUSD ?? 0,
                                             pool.budgetUSD.map { String(format: "$%.0f", $0) } ?? "∞"))
                if let cap = pool.budgetUSD, cap > 0 {
                    ProgressView(value: min((pool.spentTodayUSD ?? 0) / cap, 1))
                        .tint(pool.exhausted == true ? .red : .accentColor)
                }
            }
            if let decision = model.scheduling?.lastDecision, let text = decision.detail ?? decision.kind {
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// How many projects the fleet may run at once — the Mac's value, and a
    /// step that sends the new one straight away rather than waiting for an
    /// Apply. Under it, the projects whose run is in flight, while any is; a
    /// project that is starting says so here before its run appears anywhere.
    private var runsAtOnce: some View {
        let count = model.scheduling?.maxConcurrentRuns ?? 1
        let starting = model.scheduling?.startingProjects ?? []
        return Group {
            Stepper(value: Binding(get: { count },
                                   set: { new in Task { await model.setRunsAtOnce(client, new) } }),
                    in: 1...8) {
                Text("Runs at once: \(count)").monospacedDigit()
            }
            if !starting.isEmpty {
                Text("Starting: " + starting.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
