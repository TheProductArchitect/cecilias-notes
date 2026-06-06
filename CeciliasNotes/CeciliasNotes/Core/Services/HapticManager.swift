import UIKit

// MARK: - HapticManager

/// Centralised haptic feedback. All call-sites use the named moment methods
/// (e.g. `HapticManager.shared.pageAdded()`) — no raw `UIImpactFeedbackGenerator`
/// uses anywhere else in the app.
///
/// Two settings gates from `UserDefaults`:
/// - `ceciliasnotes.haptics.drawing` — gates drawing-time haptics (stroke begins). Default true.
/// - `ceciliasnotes.haptics.ui`      — gates all UI haptics (taps, confirmations). Default true.
///
/// Rate-limited: at most one haptic per 80 ms, regardless of caller. This protects
/// rapid-fire scenarios (e.g. dragging across many cells) from physical buzz fatigue.
@MainActor
final class HapticManager {

    static let shared = HapticManager()

    // MARK: Generators (kept warm via `prepare()`)

    private let lightImpact:    UIImpactFeedbackGenerator
    private let mediumImpact:   UIImpactFeedbackGenerator
    private let notification:   UINotificationFeedbackGenerator
    private let selection:      UISelectionFeedbackGenerator

    // MARK: Rate limit

    private var lastFiredAt: Date = .distantPast
    private let minimumInterval: TimeInterval = 0.08

    // MARK: Init

    private init() {
        self.lightImpact  = UIImpactFeedbackGenerator(style: .light)
        self.mediumImpact = UIImpactFeedbackGenerator(style: .medium)
        self.notification = UINotificationFeedbackGenerator()
        self.selection    = UISelectionFeedbackGenerator()

        [lightImpact, mediumImpact].forEach { $0.prepare() }
        notification.prepare()
        selection.prepare()
    }

    // MARK: Settings gates

    private var uiHapticsEnabled: Bool {
        // Default true if key not yet written
        UserDefaults.standard.object(forKey: "ceciliasnotes.haptics.ui") as? Bool ?? true
    }

    private var drawingHapticsEnabled: Bool {
        UserDefaults.standard.object(forKey: "ceciliasnotes.haptics.drawing") as? Bool ?? true
    }

    private func canFire(drawing: Bool = false) -> Bool {
        guard drawing ? drawingHapticsEnabled : uiHapticsEnabled else { return false }
        let now = Date()
        guard now.timeIntervalSince(lastFiredAt) >= minimumInterval else { return false }
        lastFiredAt = now
        return true
    }

    /// Persistent heavy generator for destructive confirmations. Created on
    /// demand because UIImpactFeedbackGenerator(style: .heavy) is the heaviest
    /// of the impact generators and we don't keep it warm by default.
    private lazy var heavyImpact: UIImpactFeedbackGenerator = {
        let g = UIImpactFeedbackGenerator(style: .heavy)
        g.prepare()
        return g
    }()

    // MARK: Named moments (the only public surface used by feature code)
    //
    // Bucket 3 (audit #14): each method is paired with at least one call site
    // in the app. Adding a method here without a call site is a regression.

    // Library
    func notebookCreated()           { fire(impact: lightImpact) }
    func notebookDeleted()           { fire(notification: .warning) }

    // Pages
    func pageAdded()                 { fire(impact: lightImpact) }
    func pageDeleted()               { fire(impact: mediumImpact) }

    // Drawing — gated on `ceciliasnotes.haptics.drawing` setting via canFire(drawing:)
    func strokeBegins()              { fire(impact: lightImpact, drawing: true) }

    // Tools
    func toolSwitched()              { fireSelection() }

    // Export
    func exportCompleted()           { fire(notification: .success) }
    func exportFailed()              { fire(notification: .error) }

    // iCloud
    func iCloudSyncCompleted()       { fire(impact: lightImpact) }

    // Context menus + drag-reorder
    func contextMenuOpened()         { fire(impact: mediumImpact) }
    func dragReorderStarted()        { fire(impact: mediumImpact) }
    func dragReorderDropped()        { fire(impact: lightImpact) }

    // Destructive confirmations (delete notebook, erase page, clear cache)
    func destructiveConfirmed()      { fire(impact: heavyImpact) }

    // Audio recording
    func recordingStarted()          { fire(impact: mediumImpact) }
    func recordingEnded()            { fire(impact: lightImpact) }

    // MARK: Prepare-ahead (audit #15)

    /// What's about to be triggered. Calling `prepare(for:)` 50–100 ms before
    /// the actual fire eliminates the first-trigger warm-up latency. Safe to
    /// call repeatedly — `UIFeedbackGenerator.prepare()` is cheap.
    enum HapticAction {
        case strokeBegin, contextMenu, dragReorder, destructive, recording, exportSettling
    }

    func prepare(for action: HapticAction) {
        switch action {
        case .strokeBegin, .dragReorder:           lightImpact.prepare()
        case .contextMenu, .recording:             mediumImpact.prepare()
        case .destructive:                         heavyImpact.prepare()
        case .exportSettling:                      notification.prepare()
        }
    }

    // MARK: Internal firing

    private func fire(impact: UIImpactFeedbackGenerator, drawing: Bool = false) {
        guard canFire(drawing: drawing) else { return }
        impact.impactOccurred()
        impact.prepare() // re-prime for next use
    }

    private func fire(notification type: UINotificationFeedbackGenerator.FeedbackType) {
        guard canFire() else { return }
        notification.notificationOccurred(type)
        notification.prepare()
    }

    private func fireSelection() {
        guard canFire() else { return }
        selection.selectionChanged()
        selection.prepare()
    }
}
