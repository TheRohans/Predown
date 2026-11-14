import AppKit
import PDFKit
import WebKit

struct Heading: Identifiable, Hashable {
    let id: Int
    let level: Int
    let title: String
    let pageIndex: Int
    /// Distance from the top of the page, in points.
    let offset: CGFloat
}

/// Lays markdown out with WebKit, paginates it, and captures each page as a
/// real PDF page (vector text, selectable, searchable).
@MainActor
final class PagedRenderer: NSObject, WKNavigationDelegate {

    struct Output {
        let document: PDFDocument
        let headings: [Heading]
    }

    enum RenderError: LocalizedError {
        case badScriptResult
        var errorDescription: String? { "The document couldn't be laid out." }
    }

    private let webView: WKWebView
    // WebKit is happier laying out inside a window, even one that's never shown.
    private let window: NSWindow
    private var navigation: CheckedContinuation<Void, Error>?

    override init() {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 612, height: 792), configuration: config)
        window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        super.init()
        webView.navigationDelegate = self
    }

    func render(markdown: String, fileURL: URL?, geometry g: PageGeometry) async throws -> Output {
        let base = fileURL?.deletingLastPathComponent()
        // Embed local images up front; WebKit won't reliably read files outside
        // the temp page's directory, even with <base href>.
        let body = Markdown.inlineLocalImages(in: Markdown.html(from: markdown), relativeTo: base)
        let html = Stylesheet.pagedDocument(bodyHTML: body, baseURL: base, geometry: g)

        // Load from a temp file; <base href> still resolves relative links.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("predown-\(UUID().uuidString).html")
        try html.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        resize(width: g.width, height: g.height)
        try await load(tmp)

        let result = try await callAsync(
            "return await window.predownPaginate(opts);",
            arguments: ["opts": [
                "pageHeight": Double(g.height),
                "marginTop": Double(g.marginTop),
                "marginBottom": Double(g.marginBottom),
                "pageNumbers": true,
            ]])
        guard let dict = result as? [String: Any],
              let pageCount = (dict["pages"] as? NSNumber)?.intValue, pageCount > 0
        else { throw RenderError.badScriptResult }

        // Make the view exactly as tall as the pages so every slice is in bounds.
        resize(width: g.width, height: g.height * CGFloat(pageCount))

        let pdf = PDFDocument()
        for i in 0..<pageCount {
            let cfg = WKPDFConfiguration()
            cfg.rect = CGRect(x: 0, y: g.height * CGFloat(i), width: g.width, height: g.height)
            let data = try await createPDF(cfg)
            if let page = PDFDocument(data: data)?.page(at: 0) {
                pdf.insert(page, at: pdf.pageCount)
            }
        }

        let anchors = (dict["anchors"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
        resolveInternalLinks(in: pdf, anchors: anchors, geometry: g)

        let headings = (dict["headings"] as? [[String: Any]] ?? []).enumerated().compactMap { i, h -> Heading? in
            guard let level = (h["level"] as? NSNumber)?.intValue,
                  let title = h["text"] as? String, !title.isEmpty,
                  let top = (h["top"] as? NSNumber)?.doubleValue else { return nil }
            let page = min(Int(top / g.height), pdf.pageCount - 1)
            return Heading(id: i, level: level, title: title, pageIndex: max(page, 0),
                           offset: CGFloat(top) - CGFloat(page) * g.height)
        }
        pdf.outlineRoot = Self.outline(for: headings, in: pdf)

        pdf.documentAttributes = [
            PDFDocumentAttribute.titleAttribute: Markdown.title(of: markdown) ?? fileURL?.lastPathComponent ?? "Untitled",
            PDFDocumentAttribute.creatorAttribute: "Predown",
        ]

        resize(width: g.width, height: g.height)
        return Output(document: pdf, headings: headings)
    }

    // MARK: - Outline & links

    /// Builds a nested PDF outline (what Preview shows as "Table of Contents").
    static func outline(for headings: [Heading], in pdf: PDFDocument) -> PDFOutline? {
        guard !headings.isEmpty else { return nil }
        let root = PDFOutline()
        var stack: [(level: Int, node: PDFOutline)] = [(0, root)]
        for h in headings {
            guard let page = pdf.page(at: h.pageIndex) else { continue }
            let item = PDFOutline()
            item.label = h.title
            item.destination = destination(on: page, offset: h.offset)
            while let last = stack.last, last.level >= h.level { stack.removeLast() }
            let parent = stack.last?.node ?? root
            parent.insertChild(item, at: parent.numberOfChildren)
            stack.append((h.level, item))
        }
        return root
    }

    static func destination(on page: PDFPage, offset: CGFloat) -> PDFDestination {
        let box = page.bounds(for: .mediaBox)
        // PDF space has its origin at the bottom left; leave a little air above.
        return PDFDestination(page: page, at: CGPoint(x: box.minX, y: min(box.maxY, box.maxY - offset + 12)))
    }

    /// The paginator rewrote `#fragment` links to `predown-anchor:fragment`.
    /// Turn those into real go-to-page links so they also work in exported PDFs.
    private func resolveInternalLinks(in pdf: PDFDocument, anchors: [String: Double], geometry g: PageGeometry) {
        for i in 0..<pdf.pageCount {
            guard let page = pdf.page(at: i) else { continue }
            for annotation in page.annotations {
                let url = (annotation.action as? PDFActionURL)?.url ?? annotation.url
                guard let url, url.scheme == "predown-anchor" else { continue }
                let fragment = url.absoluteString
                    .dropFirst("predown-anchor:".count)
                    .removingPercentEncoding ?? ""
                guard let top = anchors[fragment] else {
                    page.removeAnnotation(annotation)
                    continue
                }
                let target = min(Int(top / g.height), pdf.pageCount - 1)
                guard let targetPage = pdf.page(at: max(target, 0)) else { continue }
                let dest = Self.destination(on: targetPage, offset: CGFloat(top) - CGFloat(target) * g.height)
                annotation.url = nil
                annotation.action = PDFActionGoTo(destination: dest)
            }
        }
    }

    // MARK: - WebKit plumbing

    private func resize(width: CGFloat, height: CGFloat) {
        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.setContentSize(frame.size)
        webView.frame = frame
    }

    private func load(_ file: URL) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            navigation?.resume(throwing: CancellationError())
            navigation = c
            webView.loadFileURL(file, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        }
    }

    private func callAsync(_ js: String, arguments: [String: Any]) async throws -> Any? {
        try await withCheckedThrowingContinuation { c in
            webView.callAsyncJavaScript(js, arguments: arguments, in: nil, in: .page) { result in
                switch result {
                case .success(let value): c.resume(returning: value)
                case .failure(let error): c.resume(throwing: error)
                }
            }
        }
    }

    private func createPDF(_ cfg: WKPDFConfiguration) async throws -> Data {
        try await withCheckedThrowingContinuation { c in
            webView.createPDF(configuration: cfg) { c.resume(with: $0) }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishNavigation(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishNavigation(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishNavigation(error)
    }

    private func finishNavigation(_ error: Error?) {
        guard let c = navigation else { return }
        navigation = nil
        if let error { c.resume(throwing: error) } else { c.resume() }
    }
}
