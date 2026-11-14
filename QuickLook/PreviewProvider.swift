import Foundation
import QuickLookUI
import UniformTypeIdentifiers

/// Data-based Quick Look preview: renders the markdown to an HTML "sheet of
/// paper" that Quick Look displays itself. No web view of our own.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        let markdown = try Markdown.readText(at: url)
        var body = Markdown.html(from: markdown)
        let attachments = Self.embedLocalImages(in: &body, relativeTo: url.deletingLastPathComponent())
        let title = Markdown.title(of: markdown) ?? url.lastPathComponent
        let html = Stylesheet.quickLookDocument(bodyHTML: body, title: title)

        let reply = QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 860, height: 1100)) { reply in
            reply.stringEncoding = .utf8
            reply.attachments = attachments
            return Data(html.utf8)
        }
        reply.title = url.lastPathComponent
        return reply
    }

    /// Quick Look's HTML view can't load files from disk, so local images are
    /// passed along as attachments and referenced with `cid:` URLs.
    private static func embedLocalImages(in html: inout String, relativeTo dir: URL) -> [String: QLPreviewReplyAttachment] {
        var attachments: [String: QLPreviewReplyAttachment] = [:]
        html = Markdown.rewriteLocalImages(in: html, relativeTo: dir) { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            let key = "img\(attachments.count)"
            let type = UTType(filenameExtension: url.pathExtension.lowercased()) ?? .image
            attachments[key] = QLPreviewReplyAttachment(data: data, contentType: type)
            return "cid:\(key)"
        }
        return attachments
    }
}
