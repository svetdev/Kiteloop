import Foundation

/// The drawers that open between the sidebar and the center column, in
/// their left-to-right order. At most one is open: they answer different
/// questions, and two side by side leave the center column a strip.
package enum SidebarDrawer: String, CaseIterable, Sendable {
    case fleet
    case waiting

    /// The drawer the saved open flags show — the first open one in
    /// left-to-right order, so flags saved before one-at-a-time open one drawer,
    /// never two.
    package static func open(fleet: Bool, waiting: Bool) -> SidebarDrawer? {
        if fleet { return .fleet }
        return waiting ? .waiting : nil
    }

    /// The drawer open after `toggled`'s button or close is pressed while `open`
    /// is open: pressing the open drawer closes it, pressing another opens that
    /// one in its place.
    package static func afterToggling(_ toggled: SidebarDrawer, from open: SidebarDrawer?) -> SidebarDrawer? {
        open == toggled ? nil : toggled
    }
}
