import SwiftUI

// MARK: - The rule

/// Whether a hover change owes the cursor stack a push, a pop, or nothing.
///
/// `NSCursor.push()` and `NSCursor.pop()` are a stack, not a setting: a push
/// that is never balanced leaves its cursor on screen for the rest of the
/// session, everywhere in the app. Two things unbalance it, and both happen in
/// this app — AppKit reporting the same hover twice pushes twice, and a row
/// scrolled, closed or replaced out from under the pointer never reports the
/// un-hover that would have popped.
///
/// The decision is a value type with no view and no `NSCursor` in it, so the
/// rule is assertable directly; `hoverCursor(_:)` is the thin view side that
/// owns the state and makes the call.
struct HoverCursorTracker {

    /// What the caller owes the cursor stack.
    enum Action: Equatable {
        case push
        case pop
        case nothing
    }

    /// Whether this tracker currently holds a push.
    private(set) var isHovering = false

    /// A hover reported by the view. A repeat of the hover the tracker is
    /// already holding is owed nothing — that is the double-push half.
    mutating func hoverChanged(to hovering: Bool) -> Action {
        guard hovering != isHovering else { return .nothing }
        isHovering = hovering
        return hovering ? .push : .pop
    }

    /// The view going away. It owes a pop only while it holds a push — that is
    /// the stuck-cursor half.
    mutating func disappeared() -> Action {
        guard isHovering else { return .nothing }
        isHovering = false
        return .pop
    }
}

// MARK: - The view side

private struct HoverCursorModifier: ViewModifier {
    let cursor: NSCursor
    @State private var tracker = HoverCursorTracker()

    func body(content: Content) -> some View {
        content
            .onHover { hovering in apply(tracker.hoverChanged(to: hovering)) }
            .onDisappear { apply(tracker.disappeared()) }
    }

    private func apply(_ action: HoverCursorTracker.Action) {
        switch action {
        case .push: cursor.push()
        case .pop: NSCursor.pop()
        case .nothing: break
        }
    }
}

extension View {
    /// Show `cursor` while the pointer is over this view, balancing the push
    /// exactly once however the hover ends — including the view disappearing
    /// under the pointer. See `HoverCursorTracker`.
    func hoverCursor(_ cursor: NSCursor = .pointingHand) -> some View {
        modifier(HoverCursorModifier(cursor: cursor))
    }
}
