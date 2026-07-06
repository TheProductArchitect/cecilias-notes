import PencilKit
import SwiftData
import SwiftUI

/// Page-sized export snapshot — fixed bounds matching `page.pageSize`.
struct MacDocExportPageView: View {
    let page: Page
    let notebook: Notebook
    let elements: [PageElement]
    let displaySize: CGSize

    @Environment(\.theme) private var theme
    @EnvironmentObject private var storage: StorageService

    private var contentElements: [PageElement] {
        elements.filter { $0.kind != .stroke }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            MacTemplateBackground(template: page.backgroundTemplate, theme: theme)
                .frame(width: displaySize.width, height: displaySize.height)

            ZStack(alignment: .topLeading) {
                ForEach(contentElements) { element in
                    let rect = elementRect(for: element)
                    MacDocBlock(
                        element: element,
                        page: page,
                        notebook: notebook,
                        isEditing: false,
                        isSelected: false,
                        onBeginEdit: {},
                        onEndEdit: {}
                    )
                    .frame(width: rect.width, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(x: rect.minX, y: rect.minY)
                }

                if let strokeElement = elements.first(where: { $0.kind == .stroke }) {
                    MacDocExportStrokeBlock(element: strokeElement)
                        .frame(maxWidth: displaySize.width - 32)
                        .padding(.horizontal, 16)
                        .padding(.top, displaySize.height * 0.55)
                } else if pageHasHandwriting {
                    MacDocExportLegacyStrokeBlock(page: page)
                        .frame(maxWidth: displaySize.width - 32)
                        .padding(.horizontal, 16)
                        .padding(.top, displaySize.height * 0.55)
                }
            }
            .frame(width: displaySize.width, height: displaySize.height, alignment: .topLeading)
            .clipped()
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .background(theme.background)
    }

    private func elementRect(for element: PageElement) -> CGRect {
        let w = displaySize.width
        var rect = CGRect(
            x: element.normalizedX * w,
            y: element.normalizedY * displaySize.height,
            width: max(24, element.normalizedWidth * w),
            height: max(20, element.normalizedHeight * displaySize.height)
        )
        if element.kind == .text {
            let margin = MacDocPageLayout.horizontalMargin
            let contentWidth = max(40, w - 2 * margin)
            let originY = max(0, min(displaySize.height - 20, element.normalizedY * displaySize.height))
            return CGRect(
                x: margin,
                y: originY,
                width: contentWidth,
                height: max(20, rect.height)
            )
        }
        return rect
    }

    private var pageHasHandwriting: Bool {
        if elements.contains(where: { $0.kind == .stroke }) { return false }
        guard let data = storage.strokeData(for: page), !data.isEmpty else { return false }
        return (try? PKDrawing(data: data))?.bounds.isEmpty == false
    }
}

struct MacDocExportStrokeBlock: View {
    let element: PageElement
    @Environment(\.theme) private var theme

    var body: some View {
        if let image = renderedImage {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 420, alignment: .leading)
        }
    }

    private var renderedImage: NSImage? {
        guard let data = element.strokeContent?.strokeData,
              !data.isEmpty,
              let drawing = try? PKDrawing(data: data),
              !drawing.bounds.isEmpty else { return nil }
        return drawing.image(from: drawing.bounds, scale: 2)
    }
}

struct MacDocExportLegacyStrokeBlock: View {
    let page: Page
    @EnvironmentObject private var storage: StorageService

    var body: some View {
        if let image = renderedImage {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 420, alignment: .leading)
        }
    }

    private var renderedImage: NSImage? {
        guard let data = storage.strokeData(for: page),
              let drawing = try? PKDrawing(data: data),
              !drawing.bounds.isEmpty else { return nil }
        return drawing.image(from: drawing.bounds, scale: 2)
    }
}
