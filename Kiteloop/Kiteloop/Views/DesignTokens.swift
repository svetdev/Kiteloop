import SwiftUI

enum KiteloopTokens {
    enum Spacing {
        static let xs: CGFloat = 2
        static let sm: CGFloat = 4
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
    }

    enum Radius {
        static let sm: CGFloat = 4
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
    }

    enum Opacity {
        static let subtle: Double = 0.03
        static let light: Double = 0.06
        static let medium: Double = 0.12
        static let strong: Double = 0.15
    }

    enum Bubble {
        static let human = Color.blue.opacity(Opacity.strong)
        static let agent = Color(nsColor: .controlBackgroundColor)
        static let system = Color.orange.opacity(Opacity.light)
        static let error = Color.red.opacity(Opacity.light)
        static let thinking = Color.purple.opacity(0.05)
        static let toolCall = Color.orange.opacity(Opacity.subtle)
    }

    enum Anim {
        static let messageAppear: Animation = .easeOut(duration: 0.25)
        static let expand: Animation = .easeInOut(duration: 0.2)
        static let hover: Animation = .easeInOut(duration: 0.15)
    }

    enum Sidebar {
        static let width: CGFloat = 220
        static let rowHeight: CGFloat = 36
        static let iconSize: CGFloat = 16
        static let avatarSize: CGFloat = 26
        static let hoverBg = Color.primary.opacity(0.06)
        static let selectedBg = Color.accentColor.opacity(0.12)
        static let sectionSpacing: CGFloat = 20
        static let rowPadding: CGFloat = 8
    }
}
