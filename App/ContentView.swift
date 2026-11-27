import PDFKit
import SwiftUI

struct ContentView: View {
    let text: String
    let fileURL: URL?

    @StateObject private var model = DocumentModel()

    var body: some View {
        NavigationSplitView(columnVisibility: $model.columnVisibility) {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 150, ideal: 200, max: 360)
        } detail: {
            PDFKitView(view: model.pdfView)
                .overlay { placeholder }
                .frame(minWidth: 360, minHeight: 300)
        }
        .toolbar(removing: .sidebarToggle)
        .toolbar { toolbar }
        .navigationSubtitle(model.subtitle)
        .focusedSceneObject(model)
        .onAppear { model.open(text: text, url: fileURL) }
        .onChange(of: text) { _, newText in model.update(text: newText) }
    }

    @ViewBuilder private var placeholder: some View {
        if model.pdf == nil {
            if let error = model.errorMessage {
                ContentUnavailableView("Couldn't Open Document", systemImage: "doc.questionmark",
                                       description: Text(error))
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Menu {
                Picker("Sidebar", selection: sidebarSelection) {
                    Text("Hide Sidebar").tag(SidebarMode?.none)
                    Divider()
                    Text("Thumbnails").tag(SidebarMode?.some(.thumbnails))
                    Text("Table of Contents").tag(SidebarMode?.some(.contents))
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label("Sidebar", systemImage: "sidebar.left")
            } primaryAction: {
                model.toggleSidebar()
            }
            .help("Show or hide the sidebar")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $model.highlightMode) {
                Label("Highlight", systemImage: "highlighter")
            }
            .toggleStyle(.button)
            .help("Highlight text as you select it (⌃⌘H highlights the current selection)")
            .disabled(model.pdf == nil)

            Menu {
                Picker("Highlight Colour", selection: $model.highlightColor) {
                    ForEach(HighlightColor.allCases) { color in
                        Label { Text(color.name) } icon: { Image(nsImage: color.swatch) }
                            .tag(color)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label { Text("Highlight Colour") } icon: { Image(nsImage: model.highlightColor.swatch) }
            }
            .help("Highlight colour")
            .disabled(model.pdf == nil)

            ControlGroup {
                Button { model.zoomOut() } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
                    .help("Zoom out")
                Button { model.zoomIn() } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
                    .help("Zoom in")
            }
            .disabled(model.pdf == nil)

            if let fileURL {
                ShareLink(item: fileURL)
                    .help("Share")
            }

            SearchField(model: model)
                .frame(width: 180)
        }
    }

    private var sidebarSelection: Binding<SidebarMode?> {
        Binding {
            guard model.isSidebarVisible else { return nil }
            return model.sidebarMode == .searchResults ? nil : model.sidebarMode
        } set: { mode in
            if let mode { model.showSidebar(mode) } else { model.hideSidebar() }
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @ObservedObject var model: DocumentModel
    @State private var selectedHeading: Heading.ID?

    var body: some View {
        switch model.sidebarMode {
        case .thumbnails:
            ThumbnailsView(view: model.thumbnailView)
        case .contents:
            contents
        case .searchResults:
            results
        }
    }

    @ViewBuilder private var contents: some View {
        if model.headings.isEmpty {
            ContentUnavailableView("No Table of Contents", systemImage: "list.bullet.indent",
                                   description: Text("This document has no headings."))
        } else {
            let top = model.headings.map(\.level).min() ?? 1
            List(model.headings, selection: $selectedHeading) { h in
                HStack(alignment: .firstTextBaseline) {
                    Text(h.title)
                        .fontWeight(h.level == top ? .semibold : .regular)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Text("\(h.pageIndex + 1)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.leading, CGFloat(min(h.level - top, 4)) * 12)
                .tag(h.id)
            }
            .onChange(of: selectedHeading) { _, id in
                if let h = model.headings.first(where: { $0.id == id }) { model.go(to: h) }
            }
        }
    }

    @ViewBuilder private var results: some View {
        if model.searchResults.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        } else {
            List(selection: Binding(get: { model.selectedResult }, set: { model.select($0) })) {
                Section(model.searchResults.count == 1 ? "1 match" : "\(model.searchResults.count) matches") {
                    ForEach(model.searchResults) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Page \(r.pageIndex + 1)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(highlighted(r.context, model.searchText))
                                .lineLimit(2)
                        }
                        .padding(.vertical, 2)
                        .tag(r.id)
                    }
                }
            }
        }
    }

    private func highlighted(_ text: String, _ query: String) -> AttributedString {
        var s = AttributedString(text)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return s }
        var searchStart = s.startIndex
        while searchStart < s.endIndex,
              let r = s[searchStart...].range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) {
            s[r].inlinePresentationIntent = .stronglyEmphasized
            searchStart = r.upperBound
        }
        return s
    }
}

// MARK: - AppKit bridges

struct PDFKitView: NSViewRepresentable {
    let view: PDFView
    func makeNSView(context: Context) -> PDFView { view }
    func updateNSView(_ nsView: PDFView, context: Context) {}
}

struct ThumbnailsView: View {
    let view: PDFThumbnailView

    var body: some View {
        GeometryReader { geo in
            ThumbnailsRepresentable(view: view, width: geo.size.width)
        }
    }
}

private struct ThumbnailsRepresentable: NSViewRepresentable {
    let view: PDFThumbnailView
    let width: CGFloat

    func makeNSView(context: Context) -> PDFThumbnailView { view }

    func updateNSView(_ nsView: PDFThumbnailView, context: Context) {
        let w = max(60, min(width - 48, 180))
        let size = CGSize(width: w, height: (w * 1.3).rounded())
        if nsView.thumbnailSize != size { nsView.thumbnailSize = size }
    }
}

/// An NSSearchField that searches as you type, Return for next match,
/// Shift-Return for previous, Escape to clear.
struct SearchField: NSViewRepresentable {
    @ObservedObject var model: DocumentModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search"
        field.sendsSearchStringImmediately = false
        field.sendsWholeSearchString = false
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchChanged(_:))
        field.delegate = context.coordinator
        model.searchField = field
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != model.searchText { field.stringValue = model.searchText }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let model: DocumentModel
        init(model: DocumentModel) { self.model = model }

        @objc func searchChanged(_ sender: NSSearchField) {
            model.searchText = sender.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if NSEvent.modifierFlags.contains(.shift) { model.findPrevious() } else { model.findNext() }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                model.searchText = ""
                control.window?.makeFirstResponder(model.pdfView)
                return true
            default:
                return false
            }
        }
    }
}
