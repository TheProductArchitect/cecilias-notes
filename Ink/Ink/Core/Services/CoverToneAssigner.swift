import Foundation

/// Auto-assigns one of seven rotating cover tones when a notebook is
/// created. Deterministic per subject so re-running the same subject's
/// growth produces the same tone sequence; `inkBlack` is reserved for
/// explicit user choice and never enters the rotation.
///
/// The seed comes from a stable hash of the subject name (not
/// `String.hashValue` — that's salted per launch and would make the
/// sequence unstable across app restarts). The position within the
/// sequence is the count of *non-deleted* notebooks already in the
/// subject, so each new notebook lands one step further along.
enum CoverToneAssigner {

    /// Order matters: adjacent indices feel different (light → light is
    /// avoided by alternating dark accents through the rotation).
    static let rotation: [NotebookCoverTone] = [
        .parchment, .studioWhite, .ash, .coal, .midnight, .moss, .dusk
    ]

    /// Pick a tone for a notebook about to be inserted into `subject`.
    /// `existingNotebooks` is the subject's current list (after filtering
    /// out the not-yet-inserted notebook). Pass an empty array for the
    /// "no subject" case — the rotation still produces a stable choice
    /// keyed off the seed string.
    static func tone(
        forSeed seed: String,
        existingNotebooks: [Notebook]
    ) -> NotebookCoverTone {
        let live = existingNotebooks.filter { $0.isDeleted == false }
        let position = live.count
        let startIndex = stableIndex(for: seed)
        return rotation[(startIndex + position) % rotation.count]
    }

    /// Convenience: pull both inputs from a `Subject`. The subject's
    /// `notebooks` relationship is filtered for soft-deletes inside.
    static func tone(in subject: Subject) -> NotebookCoverTone {
        tone(forSeed: subject.name, existingNotebooks: subject.notebooks ?? [])
    }

    /// Convenience for the "no subject / Uncategorised" case.
    static func toneForUncategorised(
        existingNotebooks: [Notebook]
    ) -> NotebookCoverTone {
        tone(forSeed: "uncategorised", existingNotebooks: existingNotebooks)
    }

    // MARK: - Stable seed hash

    /// Deterministic, launch-stable hash of the seed string. `hashValue`
    /// is salted so it changes every process; we want the same subject
    /// name to start at the same rotation index forever.
    private static func stableIndex(for seed: String) -> Int {
        // FNV-1a 32-bit. Cheap, dependency-free, deterministic.
        var hash: UInt32 = 2166136261
        for byte in seed.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16777619
        }
        return Int(hash % UInt32(rotation.count))
    }
}
