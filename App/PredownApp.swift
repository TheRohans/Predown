import PDFKit
import SwiftUI

@main
struct PredownApp: App {
    var body: some Scene {
        DocumentGroup(viewing: MarkdownFile.self) { file in
            ContentView(text: file.document.text, fileURL: file.fileURL)
        }
        .defaultSize(width: 780, height: 1000)
        .commands {
            SidebarCommands()
            PredownCommands()
        }
    }
}

/// Menu items modelled on Preview's File / Edit / View / Go menus.
struct PredownCommands: Commands {
    @FocusedObject private var model: DocumentModel?

    private var hasDocument: Bool { model?.pdf != nil }

    var body: some Commands {
        CommandGroup(replacing: .printItem) {
            Button("Export as PDF…") { model?.exportPDF() }
                .disabled(!hasDocument)
            Divider()
            Button("Print…") { model?.printDocument() }
                .keyboardShortcut("p")
                .disabled(!hasDocument)
        }

        CommandGroup(replacing: .textEditing) {
            Menu("Find") {
                Button("Find…") { model?.focusSearch() }
                    .keyboardShortcut("f")
                Button("Find Next") { model?.findNext() }
                    .keyboardShortcut("g")
                Button("Find Previous") { model?.findPrevious() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
            }
            .disabled(!hasDocument)
        }

        CommandGroup(before: .sidebar) {
            sidebarToggle("Thumbnails", .thumbnails, key: "2")
            sidebarToggle("Table of Contents", .contents, key: "3")
            Divider()
            displayToggle("Continuous Scroll", .singlePageContinuous)
            displayToggle("Single Page", .singlePage)
            displayToggle("Two Pages", .twoUpContinuous)
            Divider()
            Button("Actual Size") { model?.actualSize() }
                .keyboardShortcut("0")
                .disabled(!hasDocument)
            Button("Zoom to Fit") { model?.zoomToFit() }
                .keyboardShortcut("9")
                .disabled(!hasDocument)
            Button("Zoom In") { model?.zoomIn() }
                .keyboardShortcut("+")
                .disabled(!hasDocument)
            Button("Zoom Out") { model?.zoomOut() }
                .keyboardShortcut("-")
                .disabled(!hasDocument)
            Divider()
            Button("Reload") { model?.reload() }
                .keyboardShortcut("r")
                .disabled(model == nil)
            Divider()
        }

        CommandMenu("Go") {
            Button("Previous Page") { model?.previousPage() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Next Page") { model?.nextPage() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Divider()
            Button("First Page") { model?.firstPage() }
            Button("Last Page") { model?.lastPage() }
        }
    }

    private func sidebarToggle(_ title: String, _ mode: SidebarMode, key: KeyEquivalent) -> some View {
        Toggle(title, isOn: Binding {
            model.map { $0.isSidebarVisible && $0.sidebarMode == mode } ?? false
        } set: { on in
            if on { model?.showSidebar(mode) } else { model?.hideSidebar() }
        })
        .keyboardShortcut(key, modifiers: [.command, .option])
        .disabled(!hasDocument)
    }

    private func displayToggle(_ title: String, _ mode: PDFDisplayMode) -> some View {
        Toggle(title, isOn: Binding {
            model?.displayMode == mode
        } set: { _ in
            model?.displayMode = mode
        })
        .disabled(!hasDocument)
    }
}
