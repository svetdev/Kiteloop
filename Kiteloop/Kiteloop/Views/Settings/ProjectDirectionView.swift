import KiteloopCore
import SwiftUI

/// Project Settings → Direction: the goal the Planner grooms against.
///
/// The goal lives in `.kiteloop/config.json` (`KiteloopProject.goal`) and is
/// what `CoordinatorQueueRefill.buildPrompt` reads to draft new backlog items.
/// Before this view existed the only place to set it was the portfolio landing
/// card, reachable only with the project closed — so a goal could not be set
/// from inside the project it steers.
///
/// The shared context is *not* edited here, though this view once did. It is
/// `.kiteloop/context.md`, read into every agent's system prompt, and the Memory
/// tab has edited it all along through `MemoryViewModel.saveSharedContext` —
/// which names neither the URL nor the filename, which is how a grep of `Views/`
/// missed it and this tab shipped a second editor for one file. It points at
/// that home now instead.
///
/// Saving the goal is explicit: it shapes every item the Planner grooms next,
/// and the write carries the project's paused switch forward unchanged, so
/// setting a goal here can never park or unpark the project.
struct ProjectDirectionView: View {
    let project: KiteloopProject

    @State private var goalText: String
    /// What `config.json` held when this view opened, so Save can be offered
    /// only for a real edit. Unlike the context editor below, this is available
    /// synchronously — reading it is a config-file read, not an async call — so
    /// there is no "not loaded yet" state to track for it.
    @State private var goalBaseline: String
    @State private var goalError: String?
    @State private var goalJustSaved = false

    /// What the file held when it was read, so Save can be offered only for a
    /// real edit and the view can tell "loaded and unchanged" from "not loaded".

    init(project: KiteloopProject) {
        self.project = project
        let goal = project.goal ?? ""
        self._goalText = State(initialValue: goal)
        self._goalBaseline = State(initialValue: goal)
    }

    private var goalDirty: Bool { goalText != goalBaseline }

    var body: some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.lg) {
            goalSection
            Divider()
            contextSection
        }
        .padding(KiteloopTokens.Spacing.lg)
    }

    // MARK: - Goal

    private var goalSection: some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.xs) {
            Text("Goal")
                .font(.system(.subheadline, weight: .semibold))
            Text("What the Planner reads to groom new backlog items against. Unset, it grooms from the code alone.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("What this project is for — optional", text: $goalText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .accessibilityIdentifier("project-direction-goal-editor")

            if let goalError {
                Text(goalError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("project-direction-goal-error")
            }

            HStack(spacing: KiteloopTokens.Spacing.md) {
                Text(goalStatusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Revert") { goalText = goalBaseline }
                    .disabled(!goalDirty)
                Button("Save", action: saveGoal)
                    .disabled(!goalDirty)
                    .accessibilityIdentifier("project-direction-goal-save")
            }
        }
    }

    private var goalStatusLine: String {
        if goalDirty { return "Unsaved changes" }
        if goalJustSaved { return "Saved — the Planner reads it on its next drafting pass" }
        return goalBaseline.isEmpty ? "Nothing stated" : "Saved"
    }

    private func saveGoal() {
        let attempt = goalText
        do {
            try project.setPaused(project.isPaused, goal: attempt)
            goalBaseline = project.goal ?? ""
            goalText = goalBaseline
            goalError = nil
            goalJustSaved = true
        } catch {
            // The view holds the only copy of the edit, so the text stays
            // exactly as typed and `goalBaseline` is left alone — the button
            // stays live and Revert still goes back to what is actually on disk.
            goalError = "Couldn't save: \(error.localizedDescription)"
            goalJustSaved = false
        }
    }

    // MARK: - Shared context

    /// Not an editor — a pointer to the one that already existed.
    ///
    /// This tab shipped with a second editor for `.kiteloop/context.md` because
    /// I grepped `Views/` for `contextURL` and `context.md`, found nothing, and
    /// concluded the app could not edit it. The Memory tab's
    /// `ProjectContextEditor` had been editing it all along; it reaches the file
    /// through `MemoryViewModel.saveSharedContext` and names neither string.
    ///
    /// Two editors on one file is the defect the daily ceiling had in three
    /// places: whichever one you are looking at reads like the place it lives.
    /// The goal above has no other home, so it stays; the context has one, so
    /// this says where it is.
    private var contextSection: some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.xs) {
            Text("Shared context")
                .font(.system(.subheadline, weight: .semibold))
            Text("What every agent receives as part of its system prompt is edited in the Memory tab, under Shared → Project Context — beside what the fleet has learned, the other file every run reads.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}
