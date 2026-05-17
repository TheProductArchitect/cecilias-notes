import SwiftUI

/// First-paint splash for the app.
///
/// Treats the splash as an emotional beat rather than a boot screen:
/// the user's name lands first ("claiming ownership"), then Cecilia's
/// sign-off arrives ("handing the app to them"). The two beats are
/// followed by a held still and a final fade-out.
///
/// State A — first launch, no name set:
///   - Title: "cecilia's." / "notes"
///   - No sign-off — Cecilia owns this paint, the user hasn't introduced
///     themselves yet, so a "yours, Cecilia" signature would read as
///     odd. The choreography is otherwise identical (Beat 1 only, plus
///     hold and fade).
/// State B — every subsequent launch:
///   - Title: "[name]'s." / "notes"
///   - Sign-off: "yours, Cecilia" — italic, recessive.
///
/// "Where your thoughts live." persists once. After the first launch
/// the `app.splash.firstLaunchSeen` flag flips and state A never
/// reappears.
struct SplashView: View {

    /// Two display modes. `RootView` picks one based on the elapsed
    /// time since the previous launch (`AppGroupLaunchTracker`):
    ///   • `.full` (default) — the full 2.7 s choreography, used for
    ///     first launch / cold launch after long gaps / onboarding-
    ///     not-completed.
    ///   • `.compressed` — name on screen, no sign-off, 0.4 s hold +
    ///     0.2 s fade (~0.8 s total). Used when the user re-opens
    ///     the app within a few hours.
    enum Mode {
        case full
        case compressed
    }

    @AppStorage(PersonalIdentity.nameKey) private var userName: String = ""
    @AppStorage("app.splash.firstLaunchSeen") private var firstLaunchSeen: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Called when the splash animation has completed and the parent
    /// should transition away.
    let onFinished: () -> Void
    /// Defaults to `.full` to preserve existing call sites. `RootView`
    /// overrides to `.compressed` when the user is returning within
    /// the 60 min–3 h window.
    var mode: Mode = .full

    // MARK: Animation phase

    private enum AnimationPhase {
        case initial          // pre-Beat 1: nothing visible
        case nameVisible      // Beat 1 settled: wordmark up
        case signoffVisible   // Beat 2 settled: signoff up; hold begins
        case fadingOut        // Exit: full crossfade to clear
    }

    @State private var phase: AnimationPhase = .initial

    // MARK: Timing constants
    //
    // Named so the choreography reads as a sequence rather than a
    // sprinkle of magic numbers. Total visible: beatTwoDelay (0.4) +
    // beatTwoAnimation (0.3) + hold (1.6) + exit (0.4) = 2.7 s.

    private let beatOneAnimation: Double = 0.3
    private let beatTwoDelay:     Double = 0.4
    private let beatTwoAnimation: Double = 0.3
    private let holdDuration:     Double = 1.6
    private let exitDuration:     Double = 0.4

    private var totalDuration: Double {
        beatTwoDelay + beatTwoAnimation + holdDuration + exitDuration
    }
    private var exitTriggerDelay: Double {
        beatTwoDelay + beatTwoAnimation + holdDuration
    }

    // MARK: Derived state

    /// True when this paint should show state A (no sign-off, unknown
    /// name). Drops false the first time the splash ever runs.
    private var isFirstLaunch: Bool { !firstLaunchSeen }

    /// Trimmed user name with the "fallback to cecilia" applied — used
    /// for the ghost letter and accessibility label only. The wordmark
    /// goes through `NameFormatter.mastheadPossessive` itself.
    private var displayName: String {
        let normal = NameFormatter.normalised(userName)
        return normal.isEmpty ? "cecilia" : normal
    }

    private var ghostCharacter: Character {
        displayName.first ?? "c"
    }

    /// The sign-off only renders when the user has actually identified
    /// themselves — first launch is Cecilia's paint and shouldn't sign
    /// off to a stranger.
    private var hasSignoff: Bool {
        !NameFormatter.normalised(userName).isEmpty
    }

    /// 88pt baseline for iPad — the wordmark genuinely commands the
    /// screen. Long possessives back off in fixed steps to keep two
    /// lines on-screen without pushing the centre cluster off either
    /// edge. Tunable in the 80–96 range per the brief.
    private var wordmarkSize: CGFloat {
        let possessiveLength = NameFormatter.normalised(userName).count + 2
        switch possessiveLength {
        case 0...6:   return 88
        case 7...8:   return 80
        case 9...10:  return 72
        case 11...12: return 64
        default:      return 56
        }
    }

    // MARK: Body

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(.systemBackground)
                    .ignoresSafeArea()

                // Ghost letter — typographic texture behind the title.
                // Anchored to the bottom-right and intentionally
                // allowed to bleed past the safe area. Preserved from
                // the prior implementation.
                GhostLetter(
                    character: ghostCharacter,
                    size: 260,
                    onDarkBackground: false
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .offset(x: 60, y: 60)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)

                // Centre cluster — wordmark + sign-off — pulled 8%
                // above true vertical centre so the composition reads
                // like a book cover rather than a vertically-centred
                // form.
                centreCluster
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .offset(y: -proxy.size.height * 0.08)
            }
            .opacity(phase == .fadingOut ? 0 : 1)
        }
        .onAppear(perform: runAnimationSequence)
    }

    // MARK: Centre cluster

    private var centreCluster: some View {
        // Splash uses a stacked composition rather than the masthead's
        // inline `BrandWordmark` — name on line 1 with the brand-accent
        // full stop, "notes" on line 2 at the same scale. Distinct
        // from the home masthead's small "notes·" label by design.
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(NameFormatter.mastheadPossessive(for: userName))
                    .foregroundStyle(Color.primary)
                Text(".")
                    .foregroundStyle(Color.brandAccent)
            }
            .font(.system(size: wordmarkSize, weight: .heavy))
            .tracking(-0.05 * wordmarkSize)

            Text("notes")
                .font(.system(size: wordmarkSize, weight: .heavy))
                .tracking(-0.05 * wordmarkSize)
                .foregroundStyle(Color.primary)

            // Spacer between wordmark and sign-off.
            Spacer().frame(height: 16)

            // Compressed mode skips the sign-off entirely — the
            // emotional beat belongs to the once-a-day full splash.
            if hasSignoff && mode == .full {
                Text("yours, Cecilia")
                    .font(.system(size: 13, weight: .regular).italic())
                    .foregroundStyle(Color.inkRecessiveSecondary)
                    .opacity(isSignoffVisible ? 1 : 0)
                    .offset(y: isSignoffVisible ? 0 : 6)
            }
        }
        .multilineTextAlignment(.center)
        .scaleEffect(phase == .initial && !reduceMotion ? 0.96 : 1.0)
        .opacity(phase == .initial ? 0 : 1)
    }

    private var isSignoffVisible: Bool {
        phase == .signoffVisible || phase == .fadingOut
    }

    // MARK: Animation

    private func runAnimationSequence() {
        // Compressed mode — name only, 0.4 s hold, 0.2 s fade.
        // Used when the user is returning to the app within the
        // 60 min–3 h window; the full emotional choreography stays
        // for first-of-day opens.
        if mode == .compressed {
            let compressedHold: Double = 0.4
            let compressedExit: Double = 0.2
            if reduceMotion {
                // Reduce Motion: no scale, no fade-in — name is just
                // visible at full opacity for the hold, then a
                // linear fade out.
                phase = .signoffVisible
            } else {
                withAnimation(.easeOut(duration: 0.2)) {
                    phase = .nameVisible
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + compressedHold) {
                withAnimation(reduceMotion
                    ? .linear(duration: compressedExit)
                    : .easeIn(duration: compressedExit)
                ) {
                    phase = .fadingOut
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + compressedExit) {
                    finish()
                }
            }
            return
        }

        if reduceMotion {
            // Crossfade only — keep the full hold so the user has
            // time to read both elements without staggered motion.
            withAnimation(.linear(duration: 0.2)) {
                phase = .signoffVisible
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + exitTriggerDelay) {
                withAnimation(.linear(duration: exitDuration)) {
                    phase = .fadingOut
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + exitDuration) {
                    finish()
                }
            }
            return
        }

        // Beat 1 — wordmark fades in + scales 0.96 → 1.0 with spring.
        withAnimation(.spring(response: beatOneAnimation, dampingFraction: 0.85)) {
            phase = .nameVisible
        }

        // Beat 2 — sign-off fades in + translates up 6 → 0 (ease-out).
        // Delay measured from sequence start so the gap between Beat 1
        // settling and Beat 2 firing is the spec'd 0.1 s breath.
        DispatchQueue.main.asyncAfter(deadline: .now() + beatTwoDelay) {
            withAnimation(.easeOut(duration: beatTwoAnimation)) {
                phase = .signoffVisible
            }
        }

        // Hold + exit — full-screen ease-in fade after the 1.6 s hold.
        DispatchQueue.main.asyncAfter(deadline: .now() + exitTriggerDelay) {
            withAnimation(.easeIn(duration: exitDuration)) {
                phase = .fadingOut
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + exitDuration) {
                finish()
            }
        }
    }

    private func finish() {
        // Stamp the first-launch flag *before* tearing the view down so
        // the very next render of SplashView (e.g. on a rapid relaunch)
        // is in state B already.
        if isFirstLaunch {
            firstLaunchSeen = true
        }
        onFinished()
    }
}

#if DEBUG
#Preview("State A — first launch") {
    UserDefaults.standard.removeObject(forKey: PersonalIdentity.nameKey)
    UserDefaults.standard.removeObject(forKey: "app.splash.firstLaunchSeen")
    return SplashView(onFinished: {})
}

#Preview("State B — name set") {
    UserDefaults.standard.set("Sara", forKey: PersonalIdentity.nameKey)
    UserDefaults.standard.set(true, forKey: "app.splash.firstLaunchSeen")
    return SplashView(onFinished: {})
}
#endif
