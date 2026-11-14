import Foundation

/// JavaScript that turns one long HTML column into fixed-height pages.
///
/// It walks the document's blocks in order and, wherever a block would cross
/// a page's bottom margin, inserts a white spacer that pushes the rest down to
/// the top of the next page. Paragraphs and list items break between lines
/// (with orphan/widow control), code blocks break between code lines, tables
/// break between rows, and headings stay with whatever follows them.
///
/// The app then snapshots each page-sized slice of the web view into a PDF page.
enum Paginator {

    static let script = #"""
    (function () {
      const BLOCK = 'p,li,dd,dt,pre,table,blockquote,ul,ol,dl,h1,h2,h3,h4,h5,h6,hr,div,section,figure,details';
      const UNIT = 'h1,h2,h3,h4,h5,h6,p,li,dd,dt,tr,hr,img,figure,pre code .ln';
      const SPLITTABLE = new Set(['P', 'LI', 'DD', 'DT']);

      function docRect(el) {
        const r = el.getBoundingClientRect();
        return { top: r.top + scrollY, bottom: r.bottom + scrollY, left: r.left, height: r.height };
      }

      function slug(text) {
        return text.trim().toLowerCase()
          .replace(/[^\p{L}\p{N}\s_-]/gu, '')
          .replace(/\s/g, '-');
      }

      window.predownPaginate = async function (opts) {
        const H = opts.pageHeight, MT = opts.marginTop, MB = opts.marginBottom;
        const contentH = H - MT - MB;
        const KEEP = opts.keepWithNext || 48;

        // 1. Wait for images (with a cap, for slow remote images) and web fonts.
        const sleep = ms => new Promise(r => setTimeout(r, ms));
        await Promise.race([
          Promise.all([...document.images].map(img => img.complete ? 0 :
            new Promise(r => { img.addEventListener('load', r); img.addEventListener('error', r); }))),
          sleep(8000)
        ]);
        // Make sure images are decoded, or the PDF snapshot can catch them blank.
        await Promise.all([...document.images].map(img =>
          img.decode ? img.decode().catch(() => {}) : 0));
        if (document.fonts && document.fonts.ready) { await document.fonts.ready; }

        // 2. Give headings GitHub-style ids so [links](#some-heading) work, and
        //    make in-document links use a scheme the app can resolve to a page.
        const used = new Set([...document.querySelectorAll('[id]')].map(e => e.id));
        for (const h of document.querySelectorAll('h1,h2,h3,h4,h5,h6')) {
          if (h.id) continue;
          let base = slug(h.textContent) || 'section', id = base, n = 1;
          while (used.has(id)) id = base + '-' + (n++);
          used.add(id); h.id = id;
        }
        for (const a of document.querySelectorAll('a[href^="#"]')) {
          a.setAttribute('href', 'predown-anchor:' + encodeURIComponent(a.getAttribute('href').slice(1)));
        }

        // 3. One block-level span per code line so breaks can fall between lines.
        for (const code of document.querySelectorAll('pre > code')) {
          const text = code.textContent.replace(/\n$/, '');
          code.textContent = '';
          for (const line of text.split('\n')) {
            const s = document.createElement('span');
            s.className = 'ln';
            s.textContent = line.length ? line : '​';
            code.appendChild(s);
          }
        }

        // 4. Collect the units we lay out: the innermost breakable blocks.
        const leaves = [...document.querySelectorAll(UNIT)]
          .filter(el => el.matches('tr, .ln, img, hr') || !el.querySelector(BLOCK));
        const leafSet = new Set(leaves);
        const units = leaves.filter(el => {
          for (let a = el.parentElement; a; a = a.parentElement) if (leafSet.has(a)) return false;
          return true;
        });

        const pageOf = y => Math.floor(y / H);
        const pageEnd = y => pageOf(y) * H + H - MB;
        const nextStart = y => (pageOf(y) + 1) * H + MT;
        const crosses = (top, bottom) => bottom > pageEnd(top) + 0.5;

        // Set a spacer's height, then nudge it until the measured point lands on target.
        function settle(setHeight, measure, target, initial) {
          let h = Math.max(0, initial);
          setHeight(h);
          for (let i = 0; i < 4; i++) {
            const d = target - measure();
            if (Math.abs(d) < 0.25) break;
            h = Math.max(0, h + d);
            setHeight(h);
          }
        }

        function pushTo(el, target) {
          const r = docRect(el);
          let setHeight;
          if (el.tagName === 'TR') {
            const tr = document.createElement('tr');
            tr.className = 'pd-gaprow';
            const td = document.createElement('td');
            td.colSpan = 1000;
            tr.appendChild(td);
            el.parentNode.insertBefore(tr, el);
            setHeight = h => { td.style.height = h + 'px'; };
          } else {
            const gap = document.createElement('div');
            gap.className = 'pd-gap';
            el.parentNode.insertBefore(gap, el);
            setHeight = h => { gap.style.height = h + 'px'; };
          }
          settle(setHeight, () => docRect(el).top, target, target - r.top);
        }

        // Visual lines of an element, from its text and images only (so spacers
        // we've already inserted don't count as lines).
        function lines(el) {
          const rects = [];
          const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT);
          const range = document.createRange();
          for (let n = walker.nextNode(); n; n = walker.nextNode()) {
            if (n.nodeType === Node.TEXT_NODE) {
              range.selectNodeContents(n);
              rects.push(...range.getClientRects());
            } else if (n.tagName === 'IMG') {
              rects.push(n.getBoundingClientRect());
            }
          }
          const out = [];
          for (const q of rects) {
            if (q.width < 0.5 || q.height < 0.5) continue;
            const top = q.top + scrollY, bottom = q.bottom + scrollY;
            const L = out.find(l => Math.min(l.bottom, bottom) - Math.max(l.top, top) >
                                    0.5 * Math.min(l.bottom - l.top, bottom - top));
            if (L) {
              L.top = Math.min(L.top, top); L.bottom = Math.max(L.bottom, bottom); L.left = Math.min(L.left, q.left);
            } else {
              out.push({ top, bottom, left: q.left });
            }
          }
          return out.sort((a, b) => a.top - b.top);
        }

        // Break a paragraph just before `line` by inserting a block spacer at the
        // DOM position where that line starts.
        function splitBefore(el, line, target) {
          window.scrollTo(0, Math.max(0, line.top - 100));
          const range = document.caretRangeFromPoint(line.left + 1, (line.top + line.bottom) / 2 - scrollY);
          if (!range || !el.contains(range.startContainer)) { window.scrollTo(0, 0); return false; }
          const gap = document.createElement('span');
          gap.className = 'pd-gap';
          range.insertNode(gap);
          const measure = () => {
            const r = document.createRange();
            r.setStartAfter(gap);
            r.setEndAfter(el.lastChild);
            for (const q of r.getClientRects()) {
              if (q.width >= 0.5 && q.height >= 0.5) return q.top + scrollY;
            }
            return target;
          };
          settle(h => { gap.style.height = h + 'px'; }, measure, target, target - line.top);
          window.scrollTo(0, 0);
          return true;
        }

        // 5. Lay out.
        for (const el of units) {
          for (let guard = 0; guard < 500; guard++) {
            const r = docRect(el);
            if (r.height < 0.5) break;

            if (SPLITTABLE.has(el.tagName)) {
              const ls = lines(el);
              const i = ls.findIndex(l => crosses(l.top, l.bottom));
              if (i < 0) break;
              // Orphan control: don't leave just the first line at the bottom of a page.
              if (i === 0 || (i === 1 && ls.length > 2)) {
                pushTo(el, nextStart(r.top));
                if (Math.abs(docRect(el).top - r.top) < 0.5) break; // couldn't move it
                continue;
              }
              // Widow control: don't carry just the last line over to the next page.
              const j = (i === ls.length - 1 && i >= 3) ? i - 1 : i;
              if (!splitBefore(el, ls[j], nextStart(ls[j].top))) {
                if (r.height <= contentH) pushTo(el, nextStart(r.top));
                break;
              }
              continue;
            }

            const isHeading = /^H[1-6]$/.test(el.tagName);
            if (!crosses(r.top, isHeading ? r.bottom + KEEP : r.bottom)) break;
            if (r.height <= contentH) pushTo(el, nextStart(r.top));
            break;
          }
        }

        // 6. Size the document to a whole number of pages and number them.
        let contentBottom = MT;
        for (const c of document.body.children) contentBottom = Math.max(contentBottom, docRect(c).bottom);
        const pages = Math.max(1, pageOf(contentBottom - 0.5) + 1);
        document.body.style.height = (pages * H) + 'px';
        document.body.style.overflow = 'hidden';

        if (opts.pageNumbers && pages > 1) {
          for (let k = 0; k < pages; k++) {
            const n = document.createElement('div');
            n.className = 'pd-pnum';
            n.textContent = String(k + 1);
            n.style.top = (k * H + H - MB / 2 - 5) + 'px';
            document.body.appendChild(n);
          }
        }

        // 7. Report headings (for the outline) and anchor positions (for links).
        const headings = [...document.querySelectorAll('h1,h2,h3,h4,h5,h6')].map(h => ({
          level: Number(h.tagName[1]), text: h.textContent.trim(), top: docRect(h).top
        }));
        const anchors = {};
        for (const e of document.querySelectorAll('[id]')) anchors[e.id] = docRect(e).top;
        window.scrollTo(0, 0);
        return { pages: pages, headings: headings, anchors: anchors };
      };
    })();
    """#
}
