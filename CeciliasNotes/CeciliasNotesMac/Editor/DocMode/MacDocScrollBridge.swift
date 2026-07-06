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

        init(scrollOffset: Binding<CGFloat>) {
            _scrollOffset = scrollOffset
        }

        func attach(to view: NSView) {
            Task { @MainActor [weak self, weak view] in
                guard let self, let view, let scrollView = view.enclosingScrollView else { return }
                let clipView = scrollView.contentView
                clipView.postsBoundsChangedNotifications = true
                self.boundsObserver = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: clipView,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.scrollOffset = clipView.bounds.origin.y
                    }
                }
                self.scrollOffset = clipView.bounds.origin.y
            }
        }

        func scroll(to offset: CGFloat, from view: NSView) {
            guard let scrollView = view.enclosingScrollView else { return }
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
