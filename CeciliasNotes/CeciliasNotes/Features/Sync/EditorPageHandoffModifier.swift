#if os(iOS)
import SwiftUI

/// Publishes `NSUserActivity` for Continuity Handoff while the
/// iOS editor is open.
struct EditorPageHandoffModifier: ViewModifier {
    @ObservedObject var viewModel: EditorViewModel

    func body(content: Content) -> some View {
        content.userActivity(PageHandoff.activityType, isActive: true) { activity in
            let page = viewModel.currentPage
            activity.title = viewModel.notebook.title
            activity.userInfo = PageHandoff.userInfo(
                notebookId: viewModel.notebook.id,
                pageId: page.id,
                scrollOffset: 0,
                zoom: viewModel.zoomScale
            )
            activity.isEligibleForHandoff = true
            activity.requiredUserInfoKeys = Set([
                PageHandoff.notebookIdKey,
                PageHandoff.pageIdKey,
            ])
        }
    }
}

extension View {
    func editorPageHandoff(_ viewModel: EditorViewModel) -> some View {
        modifier(EditorPageHandoffModifier(viewModel: viewModel))
    }
}
#endif
