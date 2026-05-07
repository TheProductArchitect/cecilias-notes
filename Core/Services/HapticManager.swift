import UIKit

// MARK: - HapticManager

/// Centralised haptic feedback. All call-sites use the named moment methods
/// (e.g. `HapticManager.shared.notebookCreated()`) — no raw `UIImpactFeedbackGenerator`
/// uses anywhere else in the app.
///
/// Two settings gates from `UserDefaults`:
/// - `ink.haptics.drawing` — gates drawing-time haptics (stroke begins). Default true.
/// - `ink.haptics.ui`      — gates all UI haptics (taps, confirmations). Default true.
///
/// Rate-limited: at most one haptic per 80 ms, regardless of caller. This protects
/// rapid-fire scenarios (e.g. dragging across many cells) from physical buzz fatigue.
@MainActor
final class HapticManager {

    static let shared = HapticManager()

    // MARK: Generators (kept warm via `prepare()`)

    private let lightImpact:    UIImpactFeedbackGenerator
    private let mediumImpact:   UIImpactFeedbackGenerator
    private let rigidImpact:    UIImpactFeedbackGenerator
    private let notification:   UINotificationFeedbackGenerator
    private let selection:      UISelectionFeedbackGenerator

    // MARK: Rate limit

    private var lastFiredAt: Date = .distantPast
    private let minimumInterval: TimeInterval = 0.08

    // MARK: Init

    private init() {
        self.lightImpact  = UIImpactFeedbackGenerator(style: .light)
        self.mediumImpact = UIImpactFeedbackGenerator(style: .medium)
        self.rigidImpact  = UIImpactFeedbackGenerator(style: .rigid)
        self.notification = UINotificationFeedbackGenerator()
        self.selection    = UISelectionFeedbackGenerator()

        [lightImpact, mediumImpact, rigidImpact].forEach { $0.prepare() }
        notification.prepare()
        selection.prepare()
    }

    // MARK: Settings gates

    private var uiHapticsEnabled: Bool {
        // Default true if key not yet written
        UserDefaults.standard.object(forKey: "ink.haptics.ui") as? Bool ?? true
    }

    private var drawingHapticsEnabled: Bool {
        UserDefaults.standard.object(forKey: "ink.haptics.drawing") as? Bool ?? true
    }

    private func canFire(drawing: Bool = false) -> Bool {
        guard drawing ? drawingHapticsEnabled : uiHapticsEnabled else { return false }
        let now = Date()
        guard now.timeIntervalSince(lastFiredAt) >= minimumInterval else { return false }
        lastFiredAt = now
        return true
    }

    // MARK: Named moments (the only public surface used by feature code)

    func notebookCreated()           { fire(impact: mediumImpact) }
    func notebookDeleted()           { fire(notification: .warning) }
    func pageAdded()                 { fire(impact: lightImpact) }
    func pageDeleted()               { fire(notification: .warning) }
    func strokeBegins()              { fire(impact: lightImpact, drawing: true) }
    func toolSwitched()              { fireSelection() }
    func exportCompleted()           { fire(notification: .success) }
    func exportFailed()              { fire(notification: .error) }
    func iCloudSyncCompleted()       { fire(notification: .success) }
    func contextMenuOpened()         { fire(impact: lightImpact) }
    func dragReorderStarted()        { fire(impact: mediumImpact) }
    func dragReorderDropped()        { fire(impact: rigidImpact) }
    func destructiveConfirmed()      { fire(notification: .warning) }

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
