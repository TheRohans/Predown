import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

enum SidebarMode: Hashable {
    case thumbnails, contents, searchResults
}

struct SearchResult: Identifiable {
    let id: Int
    let selection: PDFSelection
    let pageIndex: Int
    let context: String
}

/// One open markdown window: renders the file to PDF, owns the PDFKit views,
/// and implements everything the toolbar and menus do.
@MainActor
final class DocumentModel: ObservableObject {

    @Published private(set) var pdf: PDFDocument?
    @Published private(set) var headings: [Heading] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var currentPage = 0

    @Published var columnVisibility: NavigationSplitViewVisibility = .detailOnly
    @Published var sidebarMode: SidebarMode = .thumbnails

    @Published private(set) var searchResults: [SearchResult] = []
    @Published var selectedResult: SearchResult.ID?
    @Published var searchText = "" {
        didSet { if searchText != oldValue { runSearch() } }
    }

    @Published var displayMode: PDFDisplayMode = .singlePageContinuous {
        didSet { pdfView.displayMode = displayMode }
    }

    let pdfView = PDFView()
    let thumbnailView = PDFThumbnailView()
    weak var searchField: NSSearchField?

    private(set) var fileURL: URL?
    private var text: String?
    private let renderer = PagedRenderer()
    private var watcher: FileWatcher?
    private var isRendering = false
    private var needsRender = false
    private var modeBeforeSearch: SidebarMode = .thumbnails
    private var visibilityBeforeSearch: NavigationSplitViewVisibility = .detailOnly
    nonisolated(unsafe) private var pageObserver: NSObjectProtocol?

    init() {
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.displayBox = .cropBox
        pdfView.autoScales = true
        pdfView.pageShadowsEnabled = true

        thumbnailView.pdfView = pdfView
        thumbnailView.maximumNumberOfColumns = 1
        thumbnailView.backgroundColor = .clear
        thumbnailView.allowsDragging = false
        thumbnailView.allowsMultipleSelection = false

        pageObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged, object: pdfView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateCurrentPage() }
        }
    }

    deinit {
        if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
    }

    var pageCount: Int { pdf?.pageCount ?? 0 }

    var subtitle: String {
        guard pageCount > 0 else { return "" }
        return pageCount == 1 ? "1 page" : "Page \(currentPage + 1) of \(pageCount)"
    }

    // MARK: - Loading & rendering

    func open(text: String, url: URL?) {
        if fileURL == nil, let url {
            fileURL = url
            watcher = FileWatcher(url: url) { [weak self] in
                MainActor.assumeIsolated { self?.reloadFromDisk() }
            }
        }
        update(text: text)
    }

    func update(text newText: String) {
        guard newText != text else { return }
        text = newText
        render()
    }

    func reloadFromDisk() {
        guard let fileURL, let newText = try? Markdown.readText(at: fileURL) else { return }
        update(text: newText)
    }

    /// Re-reads the file and always re-lays it out (e.g. after the default paper size changed).
    func reload() {
        if let fileURL, let newText = try? Markdown.readText(at: fileURL) { text = newText }
        render()
    }

    private func render() {
        if isRendering { needsRender = true; return }
        isRendering = true
        Task {
            repeat {
                needsRender = false
                do {
                    let output = try await renderer.render(
                        markdown: text ?? "", fileURL: fileURL, geometry: Self.pageGeometry())
                    install(output)
                    errorMessage = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
            } while needsRender
            isRendering = false
        }
    }

    /// Swaps in a freshly rendered document, keeping the reader's place and zoom.
    private func install(_ output: PagedRenderer.Output) {
        let isReload = pdf != nil
        var place: (page: Int, point: CGPoint)?
        if isReload, let dest = pdfView.currentDestination, let page = dest.page, let old = pdf {
            place = (old.index(for: page), dest.point)
        }
        let autoScales = pdfView.autoScales
        let scale = pdfView.scaleFactor

        pdfView.document = output.document
        pdf = output.document
        headings = output.headings

        if isReload {
            if autoScales { pdfView.autoScales = true } else { pdfView.scaleFactor = scale }
            if let place, output.document.pageCount > 0,
               let page = output.document.page(at: min(place.page, output.document.pageCount - 1)) {
                pdfView.go(to: PDFDestination(page: page, at: place.point))
            }
        }
        updateCurrentPage()
        if !searchText.isEmpty { runSearch(jumpToFirst: false) }
    }

    /// The user's default paper size (System Settings > Printers), with 1" margins.
    static func pageGeometry() -> PageGeometry {
        let size = NSPrintInfo.shared.paperSize
        guard size.width >= 300, size.height >= 400 else { return .letter }
        return PageGeometry(width: size.width.rounded(), height: size.height.rounded())
    }

    private func updateCurrentPage() {
        guard let pdf, let page = pdfView.currentPage else { currentPage = 0; return }
        currentPage = pdf.index(for: page)
    }

    // MARK: - Sidebar

    var isSidebarVisible: Bool { columnVisibility != .detailOnly }

    func showSidebar(_ mode: SidebarMode) {
        sidebarMode = mode
        columnVisibility = .all
    }

    func hideSidebar() { columnVisibility = .detailOnly }

    func toggleSidebar() { columnVisibility = isSidebarVisible ? .detailOnly : .all }

    func go(to heading: Heading) {
        guard let page = pdf?.page(at: heading.pageIndex) else { return }
        pdfView.go(to: PagedRenderer.destination(on: page, offset: heading.offset))
    }

    // MARK: - Search

    func focusSearch() {
        guard let field = searchField else { return }
        field.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private func runSearch(jumpToFirst: Bool = true) {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        pdfView.highlightedSelections = nil
        guard let pdf, !query.isEmpty else {
            searchResults = []
            selectedResult = nil
            pdfView.clearSelection()
            if sidebarMode == .searchResults {
                sidebarMode = modeBeforeSearch
                columnVisibility = visibilityBeforeSearch
            }
            return
        }

        let selections = pdf.findString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
        searchResults = selections.enumerated().map { i, sel in
            let pageIndex = sel.pages.first.map { pdf.index(for: $0) } ?? 0
            let line = (sel.copy() as? PDFSelection) ?? sel
            line.extendForLineBoundaries()
            let context = (line.string ?? query)
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            return SearchResult(id: i, selection: sel, pageIndex: pageIndex, context: context)
        }
        for sel in selections { sel.color = .findHighlightColor }
        pdfView.highlightedSelections = selections

        if sidebarMode != .searchResults {
            modeBeforeSearch = sidebarMode
            visibilityBeforeSearch = columnVisibility
        }
        showSidebar(.searchResults)

        if jumpToFirst {
            let visible = currentPage
            let first = searchResults.first { $0.pageIndex >= visible } ?? searchResults.first
            if let first { select(first.id) } else { selectedResult = nil }
        }
    }

    func select(_ id: SearchResult.ID?) {
        guard let id, let result = searchResults.first(where: { $0.id == id }) else { return }
        if selectedResult != id { selectedResult = id }
        pdfView.setCurrentSelection(result.selection, animate: true)
        pdfView.go(to: result.selection)
    }

    func findNext() { step(by: 1) }
    func findPrevious() { step(by: -1) }

    private func step(by delta: Int) {
        guard !searchResults.isEmpty else { focusSearch(); return }
        let current = selectedResult ?? -delta
        let next = (current + delta + searchResults.count) % searchResults.count
        select(next)
    }

    // MARK: - Zoom & navigation

    func zoomIn() { pdfView.zoomIn(nil) }
    func zoomOut() { pdfView.zoomOut(nil) }
    func actualSize() { pdfView.autoScales = false; pdfView.scaleFactor = 1 }
    func zoomToFit() { pdfView.autoScales = true }

    func previousPage() { pdfView.goToPreviousPage(nil) }
    func nextPage() { pdfView.goToNextPage(nil) }
    func firstPage() { pdfView.goToFirstPage(nil) }
    func lastPage() { pdfView.goToLastPage(nil) }

    // MARK: - Print & export

    func printDocument() {
        guard let pdf, let window = pdfView.window else { return }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
        guard let op = pdf.printOperation(for: info, scalingMode: .pageScaleDownToFit, autoRotate: true) else { return }
        op.jobTitle = exportName
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    func exportPDF() {
        guard let pdf, let window = pdfView.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = exportName + ".pdf"
        panel.canCreateDirectories = true
        if let dir = fileURL?.deletingLastPathComponent() { panel.directoryURL = dir }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            if !pdf.write(to: url) {
                NSAlert(error: CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]))
                    .beginSheetModal(for: window)
            }
        }
    }

    private var exportName: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }
}
