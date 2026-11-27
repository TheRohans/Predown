import AppKit
import PDFKit

/// PDFView with two hooks for highlighting: extra context-menu items, and a
/// callback when the user finishes a click/drag (to highlight as they select).
final class PredownPDFView: PDFView {

    /// Items to put at the top of the context menu. Gets the annotation under
    /// the click, if any.
    var contextItems: ((PDFAnnotation?) -> [NSMenuItem])?

    /// Called after mouse up.
    var onMouseUp: (() -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let point = convert(event.locationInWindow, from: nil)
        var annotation: PDFAnnotation?
        if let page = page(for: point, nearest: false) {
            annotation = page.annotation(at: convert(point, to: page))
        }
        let items = contextItems?(annotation) ?? []
        guard !items.isEmpty else { return menu }
        if menu.numberOfItems > 0 { menu.insertItem(.separator(), at: 0) }
        for item in items.reversed() { menu.insertItem(item, at: 0) }
        return menu
    }

    // PDFView may track the drag inside mouseDown, so check after both.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onMouseUp?()
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        onMouseUp?()
    }
}
