import AppKit
import SwiftUI

/// Bridges SwiftUI `ScrollView` to `NSScrollView` for handoff scroll
/// offset read/write in doc mode.
struct MacDocScrollBridge: NSViewRepresentable {
    @Binding var scrollOffset: CGFloat
    var applyOffset: CGFloat?

    func makeCoordinator() -> Coordinator {
        Coordinator(scrollOffset: $scrollOffset)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let target = applyOffset {
            context.coordinator.scroll(to: target, from: nsView)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    @MainActor
    final class Coordinator {
        @Binding private var scrollOffset: CGFloat
        private var boundsObserver: NSObjectProtocol?
        private var pendingOffset: CGFloat?

        init(scrollOffset: Binding<CGFloat>) {
            _scrollOffset = scrollOffset
        }

        func attach(to view: NSView) {
            Task { @MainActor [weak self, weak view] in
                guard let self, let view else { return }
                for attempt in 0..<12 {
                    if let scrollView = view.enclosingScrollView {
                        self.installBoundsObserver(on: scrollView)
                        if let pending = self.pendingOffset {
                            self.applyScroll(scrollView, offset: pending)
                            self.pendingOffset = nil
                        }
                        return
                    }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    if attempt == 11 {
                        // Last resort — view hierarchy may not be ready yet.
                        _ = view
                    }
                }
            }
        }

        func scroll(to offset: CGFloat, from view: NSView) {
            if let scrollView = view.enclosingScrollView {
                applyScroll(scrollView, offset: offset)
            } else {
                pendingOffset = offset
                Task { @MainActor [weak self, weak view] in
                    guard let self, let view else { return }
                    for _ in 0..<12 {
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        guard let scrollView = view.enclosingScrollView else { continue }
                        self.applyScroll(scrollView, offset: offset)
                        self.pendingOffset = nil
                        return
                    }
                }
            }
        }

        private func installBoundsObserver(on scrollView: NSScrollView) {
            guard boundsObserver == nil else { return }
            let clipView = scrollView.contentView
            clipView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.scrollOffset = clipView.bounds.origin.y
                }
            }
            scrollOffset = clipView.bounds.origin.y
        }

        private func applyScroll(_ scrollView: NSScrollView, offset: CGFloat) {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            scrollOffset = offset
        }

        func teardown() {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
                self.boundsObserver = nil
            }
        }
    }
}
