import Foundation
import CoreGraphics

/// Page size and margins, in PDF points. In the paged renderer one CSS px
/// becomes one PDF point, so these double as CSS pixel values.
struct PageGeometry: Equatable {
    var width: CGFloat
    var height: CGFloat
    var marginTop: CGFloat = 72
    var marginBottom: CGFloat = 72
    var marginLeft: CGFloat = 72
    var marginRight: CGFloat = 72

    static let letter = PageGeometry(width: 612, height: 792)
    static let a4 = PageGeometry(width: 595, height: 842)

    var contentHeight: CGFloat { height - marginTop - marginBottom }
}

/// The look of a rendered page: a quietly typeset document, black on white
/// paper, regardless of light/dark mode (it's meant to read like a PDF).
enum Stylesheet {

    static let document = """
    :root {
      --text: #1d1d1f;
      --muted: #6e6e73;
      --rule: #d2d2d7;
      --code-bg: #f5f5f7;
      --code-border: #e5e5ea;
      --link: #0a5bd3;
    }
    body {
      font-family: ui-serif, "New York", "Iowan Old Style", Georgia, serif;
      font-size: 11px;
      line-height: 1.55;
      color: var(--text);
      -webkit-font-smoothing: antialiased;
      font-kerning: normal;
      font-variant-ligatures: common-ligatures;
      /* No auto-hyphenation: split words break search and highlight anchoring. */
      -webkit-hyphens: manual;
      hyphens: manual;
      overflow-wrap: break-word;
    }
    body > :first-child { margin-top: 0 !important; }

    h1, h2, h3, h4, h5, h6 {
      font-family: -apple-system, "SF Pro Display", "Helvetica Neue", sans-serif;
      font-weight: 600;
      line-height: 1.25;
      color: #000;
      -webkit-hyphens: manual;
      hyphens: manual;
    }
    h1 { font-size: 22px; margin: 0 0 14px; letter-spacing: -0.2px; }
    h2 { font-size: 16px; margin: 24px 0 8px; padding-bottom: 3px; border-bottom: 0.5px solid var(--rule); }
    h3 { font-size: 13px; margin: 18px 0 6px; }
    h4 { font-size: 11.5px; margin: 14px 0 4px; }
    h5, h6 { font-size: 10px; margin: 12px 0 4px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.4px; }

    p { margin: 0 0 8px; }
    a { color: var(--link); text-decoration: none; }
    strong { font-weight: 600; }
    mark { background: #fff2a8; color: inherit; padding: 0 1px; }
    del { color: var(--muted); }
    sup, sub { font-size: 0.75em; line-height: 0; }
    hr { border: none; border-top: 0.5px solid var(--rule); margin: 18px 0; }

    ul, ol { margin: 0 0 8px; padding-left: 20px; }
    li { margin: 0 0 2px; }
    li > p { margin: 0 0 4px; }
    li > ul, li > ol { margin: 2px 0 2px; }
    li.task-list-item { list-style: none; margin-left: -16px; }
    li.task-list-item input { margin: 0 6px 0 0; vertical-align: -1px; }

    code, pre, kbd, x-equation {
      font-family: ui-monospace, "SF Mono", Menlo, monospace;
    }
    code {
      font-size: 0.86em;
      background: var(--code-bg);
      border: 0.5px solid var(--code-border);
      border-radius: 3px;
      padding: 0 3px;
    }
    pre {
      font-size: 9.2px;
      line-height: 1.5;
      background: var(--code-bg);
      border: 0.5px solid var(--code-border);
      border-radius: 4px;
      padding: 8px 10px;
      margin: 0 0 10px;
      white-space: pre-wrap;
      overflow-wrap: anywhere;
      -webkit-hyphens: none;
      hyphens: none;
    }
    pre code { font-size: inherit; background: none; border: none; padding: 0; }

    blockquote {
      margin: 0 0 10px;
      padding: 0 0 0 12px;
      border-left: 2px solid var(--rule);
      color: #3a3a3c;
    }
    blockquote > :last-child { margin-bottom: 0; }

    table { border-collapse: collapse; margin: 0 0 12px; font-size: 10px; line-height: 1.4; }
    th, td { border: 0.5px solid var(--rule); padding: 4px 8px; vertical-align: top; }
    th { background: var(--code-bg); font-weight: 600; text-align: left; }
    th[align=center], td[align=center] { text-align: center; }
    th[align=right], td[align=right] { text-align: right; }

    img { max-width: 100%; height: auto; }

    div[class^="admonition-"] {
      margin: 0 0 10px;
      padding: 6px 10px;
      border-left: 3px solid #0a84ff;
      background: #f0f6ff;
      border-radius: 3px;
    }
    div[class^="admonition-"] > :last-child { margin-bottom: 0; }
    p.admonition-title {
      font-family: -apple-system, sans-serif;
      font-size: 9px;
      font-weight: 700;
      letter-spacing: 0.5px;
      text-transform: uppercase;
      margin: 0 0 3px;
      color: #0a64d6;
    }
    div.admonition-tip       { border-color: #30b158; background: #eff9f1; }
    div.admonition-tip       > .admonition-title { color: #1f8a43; }
    div.admonition-important { border-color: #8e5cf7; background: #f5f0ff; }
    div.admonition-important > .admonition-title { color: #6f3fd6; }
    div.admonition-warning   { border-color: #f5a623; background: #fff7e8; }
    div.admonition-warning   > .admonition-title { color: #b56f00; }
    div.admonition-caution   { border-color: #ff453a; background: #fff0ef; }
    div.admonition-caution   > .admonition-title { color: #d12a20; }

    section.footnotes {
      margin-top: 22px;
      padding-top: 8px;
      border-top: 0.5px solid var(--rule);
      font-size: 9px;
      color: #3a3a3c;
    }
    section.footnotes ol { padding-left: 16px; }
    a.footnote-backref { margin-left: 3px; }

    x-spoiler { background: var(--text); color: var(--text); border-radius: 2px; }
    x-wikilink { color: var(--link); }
    x-equation[type=display] { display: block; text-align: center; margin: 8px 0; }
    """

    /// Page-specific rules for the paginated app renderer.
    static func paged(_ g: PageGeometry) -> String {
        """
        html, body { margin: 0; padding: 0; background: #fff; }
        body {
          width: \(g.width)px;
          box-sizing: border-box;
          padding: \(g.marginTop)px \(g.marginRight)px 0 \(g.marginLeft)px;
          position: relative;
        }
        img { max-height: \(g.contentHeight)px; object-fit: contain; }
        pre code .ln { display: block; }
        /* Spacers inserted at page breaks. The sideways shadows paint white over
           any box backgrounds or borders that would otherwise bleed into the margins. */
        .pd-gap {
          display: block;
          background: #fff;
          box-shadow: -400px 0 #fff, 400px 0 #fff;
        }
        tr.pd-gaprow td {
          padding: 0 !important;
          border: none !important;
          background: #fff;
          box-shadow: -400px 0 #fff, 400px 0 #fff;
        }
        .pd-pnum {
          position: absolute;
          left: 0; right: 0;
          text-align: center;
          font: 8.5px -apple-system, sans-serif;
          color: #8e8e93;
        }
        """
    }

    /// Rules for Quick Look: one continuous sheet of paper on a grey desk.
    static let quickLook = """
    html { background: #e8e8e8; }
    @media (prefers-color-scheme: dark) { html { background: #2a2a2a; } }
    body { margin: 0; padding: 24px 0 32px; }
    .sheet {
      width: 612px;
      min-height: 792px;
      box-sizing: border-box;
      margin: 0 auto;
      padding: 64px 72px;
      background: #fff;
      box-shadow: 0 0 0 0.5px rgba(0,0,0,0.12), 0 2px 10px rgba(0,0,0,0.22);
      zoom: 1.3;
    }
    """

    static func pagedDocument(bodyHTML: String, baseURL: URL?, geometry: PageGeometry) -> String {
        let base = baseURL.map { "<base href=\"\(Markdown.escapeHTML($0.absoluteString))\">" } ?? ""
        return """
        <!DOCTYPE html>
        <html lang="en"><head><meta charset="utf-8">\(base)
        <style>\(document)</style>
        <style>\(paged(geometry))</style>
        <script>\(Paginator.script)</script>
        </head><body>
        \(bodyHTML)
        </body></html>
        """
    }

    static func quickLookDocument(bodyHTML: String, title: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="en"><head><meta charset="utf-8">
        <title>\(Markdown.escapeHTML(title))</title>
        <style>\(document)</style>
        <style>\(quickLook)</style>
        </head><body><div class="sheet">
        \(bodyHTML)
        </div></body></html>
        """
    }
}
