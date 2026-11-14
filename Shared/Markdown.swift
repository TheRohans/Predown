import Foundation
import UniformTypeIdentifiers

/// Markdown -> HTML via md4c, plus the small amount of text handling both
/// the app and the Quick Look extension need.
enum Markdown {

    /// Renders a markdown string to an HTML fragment (no <html>/<body>).
    static func html(from markdown: String) -> String {
        let source = stripFrontMatter(markdown)
        var output = Data()
        let bytes = Array(source.utf8)

        withUnsafeMutablePointer(to: &output) { outPtr in
            bytes.withUnsafeBufferPointer { buf in
                buf.baseAddress?.withMemoryRebound(to: CChar.self, capacity: buf.count) { cstr in
                    _ = predown_render_html(cstr, UInt32(buf.count), { data, size, userdata in
                        guard let data, let userdata else { return }
                        let out = userdata.assumingMemoryBound(to: Data.self)
                        data.withMemoryRebound(to: UInt8.self, capacity: Int(size)) {
                            out.pointee.append($0, count: Int(size))
                        }
                    }, outPtr)
                }
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Drops a leading YAML (`---`) or TOML (`+++`) front matter block, which
    /// would otherwise render as a horizontal rule followed by junk.
    static func stripFrontMatter(_ text: String) -> String {
        for fence in ["---", "+++"] {
            guard text.hasPrefix(fence + "\n") || text.hasPrefix(fence + "\r\n") else { continue }
            var lines = text.components(separatedBy: "\n")
            lines.removeFirst()
            if let end = lines.firstIndex(where: {
                let l = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return l == fence || (fence == "---" && l == "...")
            }) {
                return lines[(end + 1)...].joined(separator: "\n")
            }
        }
        return text
    }

    /// Reads a text file, trying UTF-8 first and then letting Foundation sniff.
    static func readText(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let s = String(data: data, encoding: .utf8) { return s }
        var encoding = String.Encoding.utf8
        if let s = try? String(contentsOf: url, usedEncoding: &encoding) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    /// The first `# Heading` in the document, if any.
    static func title(of markdown: String) -> String? {
        for line in stripFrontMatter(markdown).split(separator: "\n", omittingEmptySubsequences: true) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("# ") { return String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    // MARK: - Images

    /// Rewrites the `src` of every `<img>` that points at a local file. `transform`
    /// gets the file's URL and returns the replacement src, or nil to leave it as is.
    /// Remote (http/https/data) images are never touched.
    static func rewriteLocalImages(in html: String, relativeTo dir: URL?,
                                   _ transform: (URL) -> String?) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"<img src="([^"]*)""#) else { return html }
        let ns = html as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let srcRange = match.range(at: 1)
            result += ns.substring(with: NSRange(location: cursor, length: srcRange.location - cursor))
            cursor = srcRange.location + srcRange.length
            let src = ns.substring(with: srcRange)
            if let url = localImageURL(for: src, relativeTo: dir), let replacement = transform(url) {
                result += replacement
            } else {
                result += src
            }
        }
        result += ns.substring(from: cursor)
        return result
    }

    /// Embeds local images as `data:` URIs so the HTML needs no file access to show them.
    static func inlineLocalImages(in html: String, relativeTo dir: URL?) -> String {
        rewriteLocalImages(in: html, relativeTo: dir) { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return "data:\(mimeType(for: url));base64,\(data.base64EncodedString())"
        }
    }

    /// Resolves an `<img src>` (as md4c wrote it: HTML-escaped, percent-encoded)
    /// to a file URL, or nil if it's remote or can't be a file.
    static func localImageURL(for rawSrc: String, relativeTo dir: URL?) -> URL? {
        let src = rawSrc
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
        guard !src.isEmpty else { return nil }
        if let url = URL(string: src), let scheme = url.scheme, scheme.count > 1 {
            return url.isFileURL ? url : nil
        }
        // Drop any ?query or #fragment, then undo percent-encoding.
        let pathPart = String(src.split(separator: "#", maxSplits: 1)[0].split(separator: "?", maxSplits: 1).first ?? "")
        let path = pathPart.removingPercentEncoding ?? pathPart
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        if path.hasPrefix("~/") { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        guard let dir else { return nil }
        return dir.appendingPathComponent(path).standardizedFileURL
    }

    static func mimeType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension.lowercased())?.preferredMIMEType ?? "image/png"
    }

    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
