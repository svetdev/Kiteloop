import Foundation

extension String {
    package var containsOnlyEmoji: Bool {
        !isEmpty && count <= 4 && allSatisfy { $0.isEmoji }
    }
}

extension Character {
    package var isEmoji: Bool {
        guard let firstScalar = unicodeScalars.first else { return false }
        return firstScalar.properties.isEmoji && (firstScalar.value > 0x238C || unicodeScalars.count > 1)
    }
}
