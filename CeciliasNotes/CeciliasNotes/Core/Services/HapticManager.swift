#if os(iOS)
import UIKit

// MARK: - HapticManager

@MainActor
final class HapticManager {

    static let shared = HapticManager()

    private let lightImpact:    UIImpactFeedbackGenerator
    private let mediumImpact:   UIImpactFeedbackGenerator
    private let notification:   UINotificationFeedbackGenerator
    private let selection:      UISelectionFeedbackGenerator

    private var lastFiredAt: Date = .distantPast
    private let minimumInterval: TimeInterval = 0.08

    private init() {
        self.lightImpact  = UIImpactFeedbackGenerator(style: .light)
        self.mediumImpact = UIImpactFeedbackGenerator(style: .medium)
        self.notification = UINotificationFeedbackGenerator()
        self.selection    = UISelectionFeedbackGenerator()

        [lightImpact, mediumImpact].forEach { $0.prepare() }
        notification.prepare()
        selection.prepare()
    }

    private var uiHapticsEnabled: Bool {
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

    private lazy var heavyImpact: UIImpactFeedbackGenerator = {
        let g = UIImpactFeedbackGenerator(style: .heavy)
        g.prepare()
        return g
    }()

    func notebookCreated()           { fire(impact: lightImpact) }
    func notebookDeleted()           { fire(notification: .warning) }
    func pageAdded()                 { fire(impact: lightImpact) }
    func pageDeleted()               { fire(impact: mediumImpact) }
    func strokeBegins()              { fire(impact: lightImpact, drawing: true) }
    func toolSwitched()              { fireSelection() }
    func exportCompleted()           { fire(notification: .success) }
    func exportFailed()              { fire(notification: .error) }
    func iCloudSyncCompleted()       { fire(impact: lightImpact) }
    func contextMenuOpened()         { fire(impact: mediumImpact) }
    func dragReorderStarted()        { fire(impact: mediumImpact) }
    func dragReorderDropped()        { fire(impact: lightImpact) }
    func destructiveConfirmed()      { fire(impact: heavyImpact) }
    func recordingStarted()          { fire(impact: mediumImpact) }
    func recordingEnded()            { fire(impact: lightImpact) }

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

    private func fire(impact: UIImpactFeedbackGenerator, drawing: Bool = false) {
        guard canFire(drawing: drawing) else { return }
        impact.impactOccurred()
        impact.prepare()
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

#else

@MainActor
final class HapticManager {
    static let shared = HapticManager()
    private init() {}

    enum HapticAction {
        case strokeBegin, contextMenu, dragReorder, destructive, recording, exportSettling
    }

    func notebookCreated() {}
    func notebookDeleted() {}
    func pageAdded() {}
    func pageDeleted() {}
    func strokeBegins() {}
    func toolSwitched() {}
    func exportCompleted() {}
    func exportFailed() {}
    func iCloudSyncCompleted() {}
    func contextMenuOpened() {}
    func dragReorderStarted() {}
    func dragReorderDropped() {}
    func destructiveConfirmed() {}
    func recordingStarted() {}
    func recordingEnded() {}
    func prepare(for action: HapticAction) {}
}

#endif
