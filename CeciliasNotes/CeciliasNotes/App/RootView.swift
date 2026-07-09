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
        // DELIBERATELY NOT mirroring the user name here. `RootView`'s
        // `init` is run by SwiftUI on every parent re-evaluation
        // (≥7× during a single cold launch), which fired the
        // identity mirror in a loop and contributed to a launch-time
        // freeze. The mirror now runs from exactly two call sites:
        //   1. Onboarding commit (the user types a name, taps Continue).
        //   2. Settings → About name field commit (`.onSubmit` /
        //      focus-loss commit).
        // The defensive guard inside `mirrorNameToAppGroup` no-ops
        // any stray write when the value is unchanged, so a user
        // who upgraded across the App-Group-key boundary just sees
        // the brand fallback ("cecilia's") on the widget until their
        // next explicit name edit — acceptable trade-off vs. the
        // re-entry storm we had previously.
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

        // Crash-recovery: if the previous run didn't shut down
        // cleanly (force-quit, OOM-kill, crash), force the full
        // splash + library path regardless of `elapsed`. The 1-hour
        // skip-splash optimisation depends on the previous session
        // having torn down through a normal lifecycle — without
        // that, we can't trust any session-state. See `LaunchRecovery`
        // in `CeciliasNotesApp.swift`.
        guard LaunchRecovery.previousShutdownWasClean else {
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
                // ModalHostView (Phase 5B) mounts the single
                // app-wide `.sheet` and `.fullScreenCover` driven
                // by `ModalPresenter.shared`. Placed at the
                // library level so editor-internal modals presented
                // through the presenter sit ABOVE the
                // `editingNotebook` cover — solving the SwiftUI
                // "Currently, only presenting a single sheet is
                // supported" failure for editor-internal sheets.
                LibraryView()
                    .modifier(ModalHostView())
                    // Kick off the persisted search-index read on the
                    // first frame the library appears. `loadAsync` is
                    // idempotent — once `isLoaded` flips, subsequent
                    // calls no-op. Keeping the load out of the
                    // singleton's init means cold launch doesn't hitch
                    // on a 10MB JSON decode.
                    .task {
                        await SearchIndexService.shared.loadAsync()
                        SearchIndexService.shared.refreshAll()
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
