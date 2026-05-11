import SwiftUI

/// Root coordinator for the app. Three sequential phases:
///
///   `.splash` → always plays at cold launch, regardless of onboarding state.
///   `.onboarding` → first-launch-only; entered when `app.onboarding.completed`
///                   is `false` after the splash animation finishes.
///   `.library` → the home screen. The Library only mounts here, so its
///                `.onAppear` (which used to seed the legacy onboarding
///                cover) never fires while splash or onboarding are on
///                screen.
///
/// The previous build overlaid `SplashView` on top of `LibraryView` in a
/// ZStack. That meant the Library mounted simultaneously with the splash,
/// fired its `.onAppear`, and either (a) presented a full-screen
/// onboarding cover that obscured the splash, or (b) on dev devices
/// with `hasCompletedOnboarding == true` from earlier testing, blew
/// straight past the splash entirely. Sequential phases fix both.
struct RootView: View {

    @AppStorage(PersonalIdentity.onboardingCompletedKey)
    private var hasCompletedOnboarding: Bool = false

    @AppStorage(PersonalIdentity.nameKey)
    private var userName: String = ""

    enum LaunchPhase {
        case splash
        case onboarding
        case library
    }

    @State private var phase: LaunchPhase
    @State private var splashMode: SplashView.Mode

    init() {
        // Decide splash mode + initial phase at *init* time so the
        // ZStack mounts the right child directly. Putting this in
        // `.onAppear` would cause a one-frame flash of SplashView
        // before skipping to library.
        let onboardingDone = UserDefaults.standard.bool(
            forKey: PersonalIdentity.onboardingCompletedKey
        )
        // One-shot migration for users who completed onboarding
        // before the App Group mirror existed: copy the canonical
        // name into the shared suite so the widget reads the user's
        // possessive instead of the "cecilia's" fallback. Idempotent
        // — re-runs on every launch but only ever writes the same
        // value the user already has on disk.
        PersonalIdentity.mirrorNameToAppGroup()
        let elapsed = AppGroupLaunchTracker.consumeElapsedSinceLastOpen()

        // Onboarding-not-complete always sees the full splash —
        // the welcome moment shouldn't be bypassed by frequent
        // testing during development or the first 30 s of a fresh
        // install.
        if !onboardingDone {
            _phase = State(initialValue: .splash)
            _splashMode = State(initialValue: .full)
            return
        }

        switch elapsed {
        case .none:
            // First-ever launch with onboarding mysteriously
            // already done (e.g. dev seed). Treat as full splash.
            _phase = State(initialValue: .splash)
            _splashMode = State(initialValue: .full)
        case .some(let e) where e < 60 * 60:
            // Re-open within the hour — skip entirely.
            _phase = State(initialValue: .library)
            _splashMode = State(initialValue: .full)        // unused
        case .some(let e) where e < 3 * 60 * 60:
            // 1–3 h since last open — compressed splash.
            _phase = State(initialValue: .splash)
            _splashMode = State(initialValue: .compressed)
        default:
            // ≥ 3 h or first-real launch — full emotional beat.
            _phase = State(initialValue: .splash)
            _splashMode = State(initialValue: .full)
        }
    }

    var body: some View {
        ZStack {
            switch phase {
            case .splash:
                SplashView(
                    onFinished: { advancePastSplash() },
                    mode: splashMode
                )
                .transition(.opacity)

            case .onboarding:
                OnboardingView {
                    // Triggered ONLY after a valid name commits. Empty
                    // input is gated by the disabled Continue button
                    // and by `validateName`.
                    withAnimation(.easeInOut(duration: 0.3)) {
                        phase = .library
                    }
                }
                .transition(.opacity)

            case .library:
                LibraryView()
                    .overlay(alignment: .topLeading) {
                        #if DEBUG
                        FourFingerTapDetector {
                            // Four-finger tap opens StyleGuideView as a
                            // sheet. The overlay is always present but
                            // invisible.
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        #endif
                    }
                    // Kick off the persisted search-index read on the
                    // first frame the library appears. `loadAsync` is
                    // idempotent — once `isLoaded` flips, subsequent
                    // calls no-op. Keeping the load out of the
                    // singleton's init means cold launch doesn't hitch
                    // on a 10MB JSON decode.
                    .task {
                        await SearchIndexService.shared.loadAsync()
                    }
                    .transition(.opacity)
            }
        }
    }

    private func advancePastSplash() {
        let next: LaunchPhase = hasCompletedOnboarding ? .library : .onboarding
        withAnimation(.easeInOut(duration: 0.3)) {
            phase = next
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
