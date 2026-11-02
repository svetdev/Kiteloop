import KiteloopCore
import SwiftUI

/// Counts only actionable notifications, so the number stays small and an
/// exact one is worth more than a ceiling — a "99+" that never moves makes
/// clearing look like it did nothing.
struct NotificationBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text("\(count)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(.red))
                .fixedSize()
        }
    }
}

/// How many of the notices a window is holding the bell should be showing.
///
/// The badge is a view over the *active* project's inbox — `combinedNotificationStore`
/// is documented as exactly that — so notices belonging to the other open
/// projects travel in the same map and are deliberately not counted here.
///
/// It reads the map the window already keeps rather than asking the inbox,
/// because an inbox is an actor: the window's own refresh tick pays for that hop
/// once per open project every couple of seconds, and the badge riding it is
/// what makes an approval gate reached mid tool call — or an agent's question
/// with nothing else changing — move the number without being clicked on first.
enum NotificationBadgeCount {
    static func forActiveProject(pending: [String: [NotificationItem]],
                                 activeProjectID: String?) -> Int {
        guard let activeProjectID else { return 0 }
        return pending[activeProjectID, default: []].count(where: { $0.isActionable })
    }
}
