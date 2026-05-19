import Foundation

/// Per-word timing data for an `AudioContent` transcript. JSON-encoded
/// into `AudioContent.timingMapData` by the transcription pipeline;
/// consumed by the text element tap-to-seek interaction.
///
/// `charStart` / `charLength` are indices into
/// `AudioContent.transcript` (the full-text cached string on the
/// audio row). They match the character offsets produced by
/// `SFTranscriptionSegment.substringRange` in the recognition result.
struct TimingMap: Codable, Sendable {

    struct Word: Codable, Sendable {
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
