import AppKit
import PDFKit

// MARK: - Model

enum HighlightColor: String, Codable, CaseIterable, Identifiable {
    case yellow, green, blue, pink, purple

    var id: String { rawValue }

    var name: String { rawValue.capitalized }

    /// Preview's highlight colours.
    var color: NSColor {
        switch self {
        case .yellow: NSColor(srgbRed: 1.00, green: 0.84, blue: 0.04, alpha: 1)
        case .green:  NSColor(srgbRed: 0.42, green: 0.85, blue: 0.29, alpha: 1)
        case .blue:   NSColor(srgbRed: 0.35, green: 0.69, blue: 1.00, alpha: 1)
        case .pink:   NSColor(srgbRed: 1.00, green: 0.45, blue: 0.65, alpha: 1)
        case .purple: NSColor(srgbRed: 0.72, green: 0.52, blue: 1.00, alpha: 1)
        }
    }

    /// What goes on the annotation: translucent so the text stays readable.
    var annotationColor: NSColor { color.withAlphaComponent(0.5) }

    var swatch: NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            self.color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            NSColor.black.withAlphaComponent(0.2).setStroke()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
            return true
        }
        return image
    }
}

/// A highlight anchored by its text rather than by page position, so it can be
/// found again after the markdown is edited and re-paginated. All three strings
/// are whitespace-normalised (see `DocumentText.normalize`).
struct StoredHighlight: Codable, Identifiable, Equatable {
    var id = UUID()
    var exact: String
    var prefix: String
    var suffix: String
    var color: HighlightColor
    var created = Date()
}

// MARK: - Persistence

/// Highlights for every file, in ~/Library/Application Support/Predown/highlights.json.
/// Files are matched by path, falling back to a bookmark so highlights follow a
/// file that's been moved or renamed.
@MainActor
final class HighlightStore {
    static let shared = HighlightStore()

    private struct Record: Codable {
        var path: String
        var bookmark: Data?
        var highlights: [StoredHighlight]
    }

    private var records: [Record] = []
    private let storeURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Predown", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storeURL = dir.appendingPathComponent("highlights.json")
        if let data = try? Data(contentsOf: storeURL),
           let decoded = try? JSONDecoder().decode([Record].self, from: data) {
            records = decoded
        }
    }

    func highlights(for url: URL) -> [StoredHighlight] {
        index(for: url).map { records[$0].highlights } ?? []
    }

    func setHighlights(_ highlights: [StoredHighlight], for url: URL) {
        if let i = index(for: url) {
            if highlights.isEmpty {
                records.remove(at: i)
            } else {
                records[i].highlights = highlights
                records[i].bookmark = Self.bookmark(for: url) ?? records[i].bookmark
            }
        } else if !highlights.isEmpty {
            records.append(Record(path: Self.key(url), bookmark: Self.bookmark(for: url), highlights: highlights))
        }
        save()
    }

    private func index(for url: URL) -> Int? {
        let path = Self.key(url)
        if let i = records.firstIndex(where: { $0.path == path }) { return i }
        // Moved or renamed? Ask the bookmarks of records whose file is gone.
        for i in records.indices where !FileManager.default.fileExists(atPath: records[i].path) {
            guard let data = records[i].bookmark else { continue }
            var stale = false
            guard let resolved = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                                          relativeTo: nil, bookmarkDataIsStale: &stale),
                  Self.key(resolved) == path else { continue }
            records[i].path = path
            records[i].bookmark = Self.bookmark(for: url)
            save()
            return i
        }
        return nil
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    private static func key(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}

// MARK: - Text anchoring

/// The text of a whole PDF, with a whitespace-normalised copy for matching and
/// the bookkeeping to map between the two and back to per-page ranges.
/// All indices are UTF-16 offsets, to line up with NSRange and PDFKit.
struct DocumentText {
    private let pageStarts: [Int]
    private let pageLengths: [Int]
    private let normalized: NSString
    /// normalized index -> full-text index
    private let map: [Int]

    private static let contextLength = 40

    init(_ pdf: PDFDocument) {
        var starts: [Int] = [], lengths: [Int] = []
        var units: [unichar] = []
        var map: [Int] = []
        var offset = 0
        var lastWasSpace = true

        for i in 0..<pdf.pageCount {
            let text = (pdf.page(at: i)?.string ?? "") as NSString
            starts.append(offset)
            lengths.append(text.length)
            for j in 0..<text.length {
                let c = text.character(at: j)
                if Self.isSpace(c) {
                    if !lastWasSpace { units.append(0x20); map.append(offset + j); lastWasSpace = true }
                } else if !Self.isIgnorable(c) {
                    units.append(c); map.append(offset + j); lastWasSpace = false
                }
            }
            // Page boundaries separate words.
            if !lastWasSpace { units.append(0x20); map.append(offset + text.length); lastWasSpace = true }
            offset += text.length + 1
        }
        pageStarts = starts
        pageLengths = lengths
        normalized = NSString(characters: units, length: units.count)
        self.map = map
    }

    static func normalize(_ s: String) -> String {
        var out: [unichar] = []
        var lastWasSpace = true
        for c in s.utf16 {
            if isSpace(c) {
                if !lastWasSpace { out.append(0x20); lastWasSpace = true }
            } else if !isIgnorable(c) {
                out.append(c); lastWasSpace = false
            }
        }
        if out.last == 0x20 { out.removeLast() }
        return String(utf16CodeUnits: out, count: out.count)
    }

    private static func isSpace(_ c: unichar) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0xA0 || c == 0x2028 || c == 0x2029
    }

    private static func isIgnorable(_ c: unichar) -> Bool {
        c == 0x200B || c == 0x00AD || c == 0xFEFF   // zero-width space, soft hyphen, BOM
    }

    // MARK: Selection -> anchor

    /// Builds an anchor for whatever is selected, or nil if nothing useful is.
    func anchor(for selection: PDFSelection, in pdf: PDFDocument, color: HighlightColor) -> StoredHighlight? {
        var lo = Int.max, hi = Int.min
        for page in selection.pages {
            let pageIndex = pdf.index(for: page)
            guard pageIndex >= 0, pageIndex < pageStarts.count else { continue }
            for k in 0..<selection.numberOfTextRanges(on: page) {
                let r = selection.range(at: k, on: page)
                guard r.location != NSNotFound, r.length > 0 else { continue }
                lo = min(lo, pageStarts[pageIndex] + r.location)
                hi = max(hi, pageStarts[pageIndex] + r.location + r.length)
            }
        }
        guard lo < hi else { return nil }

        var a = lowerBound(lo), b = lowerBound(hi)
        while a < b, normalized.character(at: a) == 0x20 { a += 1 }
        while b > a, normalized.character(at: b - 1) == 0x20 { b -= 1 }
        guard a < b else { return nil }

        let p0 = max(0, a - Self.contextLength)
        let s1 = min(normalized.length, b + Self.contextLength)
        return StoredHighlight(
            exact: normalized.substring(with: NSRange(location: a, length: b - a)),
            prefix: normalized.substring(with: NSRange(location: p0, length: a - p0)),
            suffix: normalized.substring(with: NSRange(location: b, length: s1 - b)),
            color: color)
    }

    /// First normalized index whose full-text index is >= `fullIndex`.
    private func lowerBound(_ fullIndex: Int) -> Int {
        var lo = 0, hi = map.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if map[mid] < fullIndex { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    // MARK: Anchor -> pages

    /// Finds the best place for a highlight: every occurrence of its text,
    /// ranked by how well the surrounding text matches. Returns per-page ranges.
    func locate(_ h: StoredHighlight) -> [(pageIndex: Int, range: NSRange)] {
        guard !h.exact.isEmpty else { return [] }
        let exact = h.exact as NSString
        let prefix = h.prefix as NSString, suffix = h.suffix as NSString

        var best: (location: Int, score: Int)?
        var search = NSRange(location: 0, length: normalized.length)
        while search.length > 0 {
            let found = normalized.range(of: h.exact, options: .literal, range: search)
            guard found.location != NSNotFound else { break }
            let score = commonSuffix(prefix, before: found.location) + commonPrefix(suffix, after: found.upperBound)
            if best == nil || score > best!.score { best = (found.location, score) }
            let next = found.location + 1
            search = NSRange(location: next, length: normalized.length - next)
        }
        guard let best else { return [] }

        let start = map[best.location]
        let end = map[best.location + exact.length - 1] + 1
        return pageRanges(start, end)
    }

    private func commonSuffix(_ s: NSString, before index: Int) -> Int {
        var n = 0
        while n < s.length, index - n - 1 >= 0,
              s.character(at: s.length - n - 1) == normalized.character(at: index - n - 1) { n += 1 }
        return n
    }

    private func commonPrefix(_ s: NSString, after index: Int) -> Int {
        var n = 0
        while n < s.length, index + n < normalized.length,
              s.character(at: n) == normalized.character(at: index + n) { n += 1 }
        return n
    }

    private func pageRanges(_ start: Int, _ end: Int) -> [(pageIndex: Int, range: NSRange)] {
        var out: [(Int, NSRange)] = []
        for i in pageStarts.indices {
            let lo = max(start, pageStarts[i]), hi = min(end, pageStarts[i] + pageLengths[i])
            if lo < hi { out.append((i, NSRange(location: lo - pageStarts[i], length: hi - lo))) }
        }
        return out
    }
}

// MARK: - Menu items with closures

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, image: NSImage? = nil, state: NSControl.StateValue = .off, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        self.target = self
        self.image = image
        self.state = state
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}
