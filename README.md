# Predown

A markdown reader for macOS that feels like Preview.app. Double-click a `.md`
file and it opens as a paginated document: white pages on a grey desk, with
thumbnails, a table of contents, search, zoom, print and Export as PDF. It also
installs a Quick Look extension, so pressing space on a markdown file in Finder
shows it rendered.

Markdown is parsed by [md4c](https://github.com/mity/md4c) (vendored in
`third_party/md4c`, MIT). It supports CommonMark plus GitHub tables, task lists,
strikethrough, autolinks, footnotes, `> [!NOTE]` admonitions and `==highlight==`.

## How it works

- **App**: md4c turns the markdown into HTML. A hidden WebKit view lays it out at
  page width, and `Shared/Paginator.swift` (JavaScript) pushes content down so
  page breaks fall between lines, code lines and table rows, never through them.
  Each page is then captured as a real vector PDF page and shown in PDFKit's
  `PDFView`, the same view Preview uses. Headings become the PDF outline, and
  `#anchor` links become in-document links (these also work in exported PDFs).
  Page size follows your default paper size (Letter or A4) with 1" margins.
- **Quick Look**: a data-based preview extension renders the same HTML and CSS
  as one continuous sheet of paper. Local images are attached to the preview.
  The extension is sandboxed with a read-only file exception so it can read
  images next to the markdown file. That's fine for Developer ID or local use,
  but the Mac App Store wouldn't accept it. Remote (http) images don't load in
  Quick Look.
- **Live reload**: the window watches the file and re-renders when it changes,
  keeping your page and zoom.

## Requirements

macOS 14+, Xcode, CMake 3.24+ (`brew install cmake`).

## Build, sign, archive (Xcode)

```sh
cmake -G Xcode -B build                     # or: make open
open build/Predown.xcodeproj
```

In Xcode, set your Team under *Signing & Capabilities* for **both** the
`Predown` and `PredownQuickLook` targets. Then pick the `Predown` scheme and
choose Product > Archive. From the Organizer, use Distribute App > Custom >
Copy App (or Developer ID).

To skip picking the team each time you regenerate:
`cmake -G Xcode -B build -DPREDOWN_TEAM_ID=XXXXXXXXXX`.

Note that `build/` is generated: regenerating overwrites any setting changed by
hand in Xcode, so put permanent changes in `CMakeLists.txt`.

## Build from the terminal

```sh
make install          # Release build, signed to run locally, copied to /Applications
make preview FILE=sample.md
```

## After installing

1. Launch Predown once from /Applications. This registers the Quick Look extension.
2. Check System Settings > General > Login Items & Extensions > Quick Look and
   make sure *Predown Quick Look* is on.
3. To make double-click open markdown in Predown: Finder > select any `.md` >
   Get Info > Open with: Predown > Change All…
4. If an old preview is cached: `qlmanage -r && qlmanage -r cache`.

## Keyboard

| | |
|---|---|
| ⌘F / ⌘G / ⇧⌘G | Find / next / previous (Return and ⇧Return in the search field also step) |
| ⌘+ / ⌘- / ⌘0 / ⌘9 | Zoom in / out / actual size / zoom to fit |
| ⌥⌘2 / ⌥⌘3 / ⌃⌘S | Thumbnails / table of contents / toggle sidebar |
| ⌥⌘↑ / ⌥⌘↓ | Previous / next page |
| ⌘R | Reload |
| ⌘P | Print |

## Layout

```
App/         SwiftUI app: document window, toolbar, menus, renderer
QuickLook/   Quick Look preview extension
Shared/      md4c wrapper, stylesheet, paginator (compiled into both)
third_party/ md4c sources
scripts/     make_icon.py: draws the app icon (Pillow); point it at
             App/Assets.xcassets/AppIcon.appiconset to regenerate every size
```
