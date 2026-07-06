import Foundation

enum TranscriptionQuality: String, CaseIterable {
    case fast     = "fast"
    case accurate = "accurate"

    var displayName: String { rawValue.capitalized }
}
