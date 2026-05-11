import Foundation

/// Picks a greeting line from `greetings` for the Library home header.
///
/// Selection is biased by current time-of-day and weekday, then filtered
/// against a rolling window of the most recent 30 indices that have been
/// shown — so a user refreshing the home screen never sees the same line
/// twice in close succession.
///
/// Storage is a JSON-encoded `[Int]` under
/// `app.greetings.recent` in `UserDefaults`. The window trims to 30 on
/// every write. Decoding errors recover silently with an empty list.
enum GreetingPicker {

    private static let recentKey  = "app.greetings.recent"
    private static let windowSize = 30

    // MARK: Public

    /// Returns the text of a greeting, biased to the supplied date and
    /// weekday and skipping anything in the recent window. The chosen
    /// index is appended to the recent list before returning.
    static func pick(
        date: Date = Date(),
        defaults: UserDefaults = .standard,
        rng: inout SystemRandomNumberGenerator
    ) -> String {
        let timeTag    = timeOfDayTag(for: date)
        let weekdayTag = weekdayTag(for: date)

        let recent = readRecent(from: defaults)
        let recentSet = Set(recent)

        // Build the candidate pool: any greeting whose tag matches the
        // current time-of-day, the current weekday, OR is evergreen.
        var candidates: [Int] = []
        for (index, entry) in greetings.enumerated() {
            let matches = entry.tag == nil
                || entry.tag == timeTag
                || entry.tag == weekdayTag
            if matches && !recentSet.contains(index) {
                candidates.append(index)
            }
        }

        // Defensive: if the window has somehow swallowed every match
        // (small pool + very active user), fall back to the unfiltered
        // matching pool, then to evergreens, then to all greetings.
        let pool: [Int]
        if !candidates.isEmpty {
            pool = candidates
        } else {
            let unfiltered = greetings.indices.filter { i in
                let t = greetings[i].tag
                return t == nil || t == timeTag || t == weekdayTag
            }
            if !unfiltered.isEmpty {
                pool = unfiltered
            } else {
                pool = Array(greetings.indices)
            }
        }

        let chosen = pool.randomElement(using: &rng) ?? 0
        appendRecent(chosen, to: defaults)
        return greetings[chosen].text
    }

    /// Convenience overload using the system RNG.
    static func pick(
        date: Date = Date(),
        defaults: UserDefaults = .standard
    ) -> String {
        var rng = SystemRandomNumberGenerator()
        return pick(date: date, defaults: defaults, rng: &rng)
    }

    // MARK: Tagging

    /// Maps an hour to one of the four time-of-day tags from `Greetings.swift`.
    static func timeOfDayTag(for date: Date) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        switch hour {
        case 5...11:  return "morning"
        case 12...17: return "afternoon"
        case 18...22: return "evening"
        default:      return "latenight"  // 23, 0, 1, 2, 3, 4
        }
    }

    /// Maps a weekday integer (Calendar's 1 = Sunday convention) to the
    /// lowercase day-of-week tags used in `Greetings.swift`.
    static func weekdayTag(for date: Date) -> String {
        let weekday = Calendar.current.component(.weekday, from: date)
        switch weekday {
        case 1: return "sunday"
        case 2: return "monday"
        case 3: return "tuesday"
        case 4: return "wednesday"
        case 5: return "thursday"
        case 6: return "friday"
        case 7: return "saturday"
        default: return "monday"
        }
    }

    // MARK: Recent-window persistence

    private static func readRecent(from defaults: UserDefaults) -> [Int] {
        let raw = defaults.string(forKey: recentKey) ?? "[]"
        guard let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([Int].self, from: data)) ?? []
    }

    private static func appendRecent(_ index: Int, to defaults: UserDefaults) {
        var current = readRecent(from: defaults)
        current.append(index)
        if current.count > windowSize {
            current.removeFirst(current.count - windowSize)
        }
        if let data = try? JSONEncoder().encode(current),
           let json = String(data: data, encoding: .utf8) {
            defaults.set(json, forKey: recentKey)
        }
    }
}
