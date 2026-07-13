import SwiftUI
import UIKit

/// Multi-section colour picker shown as a popover anchored to the tool palette's colour dot.
struct ColorPickerView: View {
    @ObservedObject var viewModel: EditorViewModel
    let onClose: () -> Void
    @Environment(\.theme) private var theme


    /// One row of essentials. The full 40-colour grid was cramped
    /// inside the popover and most users only ever touched a
    /// handful of swatches; everything else is one tap away via
    /// "Custom Colour…". Recent selections sit above the row when
    /// the user has picked colours this session.
    private let presets: [String] = [
        "#000000", // black
        "#FFFFFF", // white
        "#FF3B30", // red
        "#FF9500", // orange
        "#FFCC00", // yellow
        "#34C759", // green
        "#007AFF", // blue
        "#AF52DE", // purple
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: CeciliasNotes.Spacing.md) {
            // Current — always-visible swatch of the active colour,
            // so the user can tell at a glance what they're drawing
            // with. Without this the active colour was only marked
            // by an accent ring on whichever preset matched (and
            // a custom-picked colour outside the preset palette
            // had no visible "current" affordance at all).
            currentSwatchSection

            // Recent
            if !viewModel.recentColours.isEmpty {
                section(title: "Recent") {
                    HStack(spacing: 8) {
                        ForEach(Array(viewModel.recentColours.enumerated()), id: \.offset) { _, colour in
                            colourCircle(colour: colour, size: 28)
                        }
                        Spacer()
                    }
                }
            }

            // Presets — one row of essentials.
            section(title: "Presets") {
                HStack(spacing: 6) {
                    ForEach(presets, id: \.self) { hex in
                        colourCircle(colour: UIColor(hex: hex), size: 28)
                    }
                }
            }

            // Custom — close the popover FIRST, then present the
            // system picker from the top-most view controller once
            // the popover has finished dismissing. Never host
            // UIColorPickerViewController inside this popover (or a
            // sheet of it): the eyedropper's screen-sampling tap
            // lands outside the popover, SwiftUI tears the popover
            // down mid-sample, and UIKit's `_pickerDidDismissEyedropper`
            // then re-presents into a destroyed hierarchy —
            // NSInvalidArgumentException, two App Store review
            // crashes (builds 2.1(1) and 2.1(3)).
            Button {
                let initial = viewModel.effectiveInkTool.currentColour
                let vm = viewModel
                onClose()
                CustomColorPickerPresenter.present(
                    initial: initial,
                    onLiveChange: { vm.selectColourLive($0) }
                ) { picked in
                    vm.selectColour(picked)
                }
            } label: {
                HStack {
                    Image(systemName: "eyedropper")
                        .foregroundColor(theme.accent)
                    Text("Custom Colour…")
                        .font(.ceciliasNotesBody)
                        .foregroundColor(theme.accent)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.ceciliasNotesPressable)

            // Opacity (pen + pencil only)
            if viewModel.effectiveInkTool.hasOpacity {
                Divider()
                opacitySlider
            }

            // Width — shown for any tool that supports a width
            // setting. Used to live in a separate popover wrapper
            // that fought ColorPickerView's own width and clipped
            // every label; folding it in here means one popover,
            // one source of truth, no clipping.
            if viewModel.effectiveInkTool.hasWidth {
                Divider()
                widthSlider
            }
        }
        .padding(CeciliasNotes.Spacing.md)
        .frame(width: 320)
        .background(theme.surfaceElevated)
        .presentationCompactAdaptation(.popover)
    }

    // MARK: Current swatch (top of popover)

    private var currentSwatchSection: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color(viewModel.effectiveInkTool.currentColour))
                .frame(width: 36, height: 36)
                .overlay(
                    Circle().strokeBorder(theme.accent, lineWidth: 2)
                )
                .overlay(
                    Circle().strokeBorder(theme.borderSubtle, lineWidth: 0.5)
                        .padding(2)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text("Current")
                    .font(.ceciliasNotesCaption)
                    .foregroundColor(theme.foregroundSubtle)
                Text(viewModel.effectiveInkTool.currentColour.hexString.uppercased())
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundColor(theme.foreground)
            }
            Spacer()
        }
    }

    // MARK: Section helper

    @ViewBuilder
    private func section<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.ceciliasNotesCaption)
                .foregroundColor(theme.foregroundSubtle)
            content()
        }
    }

    // MARK: Single swatch

    private func colourCircle(colour: UIColor, size: CGFloat) -> some View {
        let isSelected = colour.hexString == viewModel.effectiveInkTool.currentColour.hexString

        return Button {
            viewModel.selectColour(colour)
            onClose()
        } label: {
            ZStack {
                Circle()
                    .fill(Color(colour))
                    .frame(width: size, height: size)
                    .overlay(
                        Circle().strokeBorder(theme.borderSubtle, lineWidth: 0.5)
                    )
                if isSelected {
                    Circle()
                        .strokeBorder(theme.accent, lineWidth: 2)
                        .frame(width: size + 4, height: size + 4)
                }
            }
        }
        .buttonStyle(.ceciliasNotesPressable)
    }

    // MARK: Opacity slider

    private var opacitySlider: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Opacity")
                    .font(.ceciliasNotesCaption)
                    .foregroundColor(theme.foregroundSubtle)
                Spacer()
                Text("\(Int(viewModel.effectiveInkTool.currentOpacity * 100))%")
                    .font(.ceciliasNotesCaption)
                    .foregroundColor(theme.foregroundMuted)
                    .monospacedDigit()
            }
            Slider(
                value: Binding(
                    get: { Double(viewModel.effectiveInkTool.currentOpacity) },
                    set: { viewModel.setOpacity(CGFloat($0)) }
                ),
                in: 0.10...1.0
            )
            .tint(theme.accent)
        }
    }

    // MARK: Width slider

    private var widthSlider: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Width")
                    .font(.ceciliasNotesCaption)
                    .foregroundColor(theme.foregroundSubtle)
                Spacer()
                Text(widthLabel(viewModel.effectiveInkTool.currentWidth))
                    .font(.ceciliasNotesCaption)
                    .foregroundColor(theme.foregroundMuted)
                    .monospacedDigit()
            }
            Slider(
                value: Binding(
                    get: { Double(viewModel.effectiveInkTool.currentWidth) },
                    set: { viewModel.setWidth(CGFloat($0)) }
                ),
                in: 0.5...20,
                step: 0.5
            )
            .tint(theme.accent)
        }
    }

    private func widthLabel(_ width: CGFloat) -> String {
        if width == 0 { return "—" }
        if width.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(width))"
        }
        return String(format: "%.1f", width)
    }
}

// MARK: - Custom colour picker (UIColorPickerViewController, UIKit-presented)

/// Presents `UIColorPickerViewController` from the top-most view
/// controller via plain UIKit, deliberately outside any SwiftUI
/// presentation lineage.
///
/// Why not a SwiftUI `.sheet`: the picker's eyedropper hides the
/// picker window to let the user sample the screen, then UIKit
/// re-presents the picker's UI from inside
/// `_pickerDidDismissEyedropper`. If the picker was hosted by a
/// popover (or a sheet whose parent is a popover), the sampling tap
/// itself dismisses that popover, the whole presentation chain is
/// deallocated mid-sample, and the re-present throws
/// `NSInvalidArgumentException` → SIGABRT. Shipped twice from App
/// Store review devices (builds 2.1(1), 2.1(3)). A UIKit formSheet
/// on the top-most controller doesn't dismiss on outside taps, so
/// the eyedropper always returns to a live hierarchy.
@MainActor
enum CustomColorPickerPresenter {

    /// Strong reference while presented — `UIColorPickerViewController.delegate`
    /// is weak and the SwiftUI caller holds nothing.
    private static var activeDelegate: PickerDelegate?

    /// `present` is called right after the hosting popover's
    /// dismissal begins; presenting while the dismissal animates
    /// would target the dying popover controller, so wait for the
    /// top of the presentation stack to settle first.
    /// `onLiveChange` fires per colour selection while the sheet is
    /// up (ink preview without polluting the recents ring);
    /// `onPick` fires exactly once with the final colour — from the
    /// close button OR a swipe-down dismissal.
    static func present(
        initial: UIColor,
        onLiveChange: ((UIColor) -> Void)? = nil,
        onPick: @escaping (UIColor) -> Void
    ) {
        Task { @MainActor in
            // Popover dismissal animation is ~0.3s; poll briefly
            // rather than trusting one magic delay.
            for _ in 0..<6 {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if let top = topMostViewController(),
                   top.presentedViewController == nil,
                   !top.isBeingDismissed {
                    show(from: top, initial: initial,
                         onLiveChange: onLiveChange, onPick: onPick)
                    return
                }
            }
            // Stack never settled (unexpected) — degrade to not
            // showing the picker rather than risking a throw.
        }
    }

    private static func show(
        from host: UIViewController,
        initial: UIColor,
        onLiveChange: ((UIColor) -> Void)?,
        onPick: @escaping (UIColor) -> Void
    ) {
        let picker = UIColorPickerViewController()
        picker.selectedColor = initial
        picker.supportsAlpha = false
        picker.modalPresentationStyle = .formSheet
        let delegate = PickerDelegate(onLiveChange: onLiveChange, onPick: onPick)
        picker.delegate = delegate
        // Swipe-down dismissal never calls
        // `colorPickerViewControllerDidFinish` — without this
        // delegate the picked colour was silently dropped unless
        // the user tapped the sheet's close button ("custom colour
        // doesn't get selected" / "never shows in recents").
        picker.presentationController?.delegate = delegate
        activeDelegate = delegate
        host.present(picker, animated: true)
    }

    private static func topMostViewController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        var top = window?.rootViewController
        while let presented = top?.presentedViewController,
              !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    private final class PickerDelegate: NSObject,
        UIColorPickerViewControllerDelegate,
        UIAdaptivePresentationControllerDelegate {

        let onLiveChange: ((UIColor) -> Void)?
        let onPick: (UIColor) -> Void
        private var committed = false

        init(onLiveChange: ((UIColor) -> Void)?, onPick: @escaping (UIColor) -> Void) {
            self.onLiveChange = onLiveChange
            self.onPick = onPick
        }

        private func commit(_ colour: UIColor) {
            guard !committed else { return }
            committed = true
            onPick(colour)
            CustomColorPickerPresenter.activeDelegate = nil
        }

        func colorPickerViewControllerDidFinish(_ vc: UIColorPickerViewController) {
            commit(vc.selectedColor)
        }

        func colorPickerViewControllerDidSelectColor(_ vc: UIColorPickerViewController) {
            // Live ink preview only — recents are committed once, on
            // dismissal, so dragging the wheel doesn't flush the
            // 8-slot recents ring with intermediate hues.
            onLiveChange?(vc.selectedColor)
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            guard let picker = presentationController.presentedViewController
                    as? UIColorPickerViewController else { return }
            commit(picker.selectedColor)
        }
    }
}
