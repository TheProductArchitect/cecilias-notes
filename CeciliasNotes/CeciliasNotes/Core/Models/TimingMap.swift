import Foundation

/// Per-word timing data for an `AudioContent` transcript. JSON-encoded
/// into `AudioContent.timingMapData` by the transcription pipeline;
/// consumed by the text element tap-to-seek interaction.
///
/// `charStart` / `charLength` are indices into
/// `AudioContent.transcript` (the full-text cached string on the
/// audio row). They match the character offsets produced by
/// `SFTranscriptionSegment.substringRange` in the recognition result.
struct TimingMap: Codable {

    struct Word: Codable {
        let text: String
        let startTime: TimeInterval
        let endTime: TimeInterval
        /// Byte offset of the first character in the full transcript
        /// string. Used to map a tap's character index back to this word.
        let charStart: Int
        let charLength: Int
    }

    let words: [Word]
    let totalDuration: TimeInterval
    let version: Int

    /// First word whose character range contains `charIndex`. Returns
    /// nil when `charIndex` falls in whitespace between words.
    func wordContaining(charIndex: Int) -> Word? {
        words.first {
            charIndex >= $0.charStart && charIndex < $0.charStart + $0.charLength
        }
    }
}

// MARK: - AudioContent convenience

import SwiftData

extension AudioContent {
    /// Decoded `TimingMap` from `timingMapData`, or nil if the field
    /// is empty (recordings made before this feature shipped, or if
    /// recognition produced no segments). Read/write round-trips
    /// through JSON so the stored bytes stay schema-version-stable.
    var timingMap: TimingMap? {
        get {
            guard let data = timingMapData else { return nil }
            return try? JSONDecoder().decode(TimingMap.self, from: data)
        }
        set {
            timingMapData = newValue.flatMap { try? JSONEncoder().encode($0) }
        }
    }
}
