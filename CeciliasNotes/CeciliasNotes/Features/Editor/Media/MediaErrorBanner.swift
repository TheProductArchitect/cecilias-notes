import SwiftUI

// MARK: - MediaErrorBanner

/// Red banner that slides down from the top edge and auto-dismisses after 4s.
/// Shown for non-modal media insertion errors.
struct MediaErrorBanner: View {

    let message: String
    let onDismiss: () -> Void

    @State private var visible = false

    var body: some View {
        HStack(spacing: CeciliasNotes.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)

            Text(message)
                .font(.inkFootnote)
                .foregroundColor(.white)
                .lineLimit(2)

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.inkPressable)
            .inkTapTarget()
        }
        .padding(.horizontal, CeciliasNotes.Spacing.md)
        .padding(.vertical, CeciliasNotes.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: CeciliasNotes.Radius.md, style: .continuous)
                .fill(Color(UIColor(hex: "#CC2B2B")))
        )
        .padding(.horizontal, CeciliasNotes.Spacing.lg)
        .offset(y: visible ? 0 : -100)
        .opacity(visible ? 1 : 0)
        .onAppear {
            withAnimation(.inkSpring(CeciliasNotesSpring.snappy)) { visible = true }
            Task {
                try? await Task.sleep(for: .seconds(4))
                dismiss()
            }
        }
    }

    private func dismiss() {
        withAnimation(.inkSpring(CeciliasNotesSpring.smooth)) { visible = false }
        Task {
            try? await Task.sleep(for: .seconds(0.35))
            await MainActor.run { onDismiss() }
        }
    }
}
