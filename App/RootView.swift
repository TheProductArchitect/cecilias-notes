import SwiftUI

struct RootView: View {
    @EnvironmentObject private var themeManager: ThemeManager

    var body: some View {
        LibraryView()
            .overlay(alignment: .topLeading) {
                #if DEBUG
                FourFingerTapDetector {
                    // Four-finger tap opens StyleGuideView as a sheet
                    // The overlay is always present but invisible.
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                #endif
            }
    }
}

// MARK: - Four-finger tap bridge

struct FourFingerTapDetector: UIViewRepresentable {
    let onTap: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view    = PassthroughView()
        let gesture = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handle)
        )
        gesture.numberOfTouchesRequired = 4
        view.addGestureRecognizer(gesture)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    final class Coordinator: NSObject {
        let onTap: () -> Void
        init(onTap: @escaping () -> Void) { self.onTap = onTap }
        @objc func handle() { onTap() }
    }
}

private final class PassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let event, event.allTouches?.count ?? 0 >= 4 else { return nil }
        return super.hitTest(point, with: event)
    }
}
