import Foundation

/// 富文本编辑器页面：contenteditable + 命令脚本。
enum EditorHTML {
    static func page(placeholder: String) -> String {
        let ph = HTMLText.escape(placeholder).replacingOccurrences(of: "\"", with: "&quot;")
        return """
        <!doctype html>
        <html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <meta name="color-scheme" content="light">
        <style>
        html, body { margin: 0; padding: 0; background: #fff; }
        #ed { min-height: 100vh; padding: 14px 14px 60px; box-sizing: border-box; outline: none;
              \(MIMEBuilder.defaultBodyStyle)
              -webkit-user-select: text; user-select: text; overflow-wrap: anywhere; word-wrap: break-word; caret-color: #000; }
        #ed:empty:before { content: attr(data-ph); color: #9a9a9a; }
        #ed img { max-width: 100%; height: auto; }
        #ed table { border-collapse: collapse; max-width: 100%; }
        #ed td, #ed th { min-width: 40px; }
        #ed blockquote { margin: 0 0 0 6px; padding-left: 10px; border-left: 2px solid #999; }
        #ed pre { white-space: pre-wrap; font-family: Menlo, Consolas, monospace; background: #f4f4f4; padding: 6px; }
        #ed a { color: #0563c1; }
        #ed ul, #ed ol { padding-left: 28px; }
        </style>
        </head><body>
        <div id="ed" contenteditable="true" spellcheck="true" autocorrect="on" data-ph="\(ph)"></div>
        <script>\(script)</script>
        </body></html>
        """
    }

    static let script = #"""
    var ed = document.getElementById('ed');
    var saved = null;
    var painter = null;
    function post(n, b) { try { window.webkit.messageHandlers[n].postMessage(b); } catch (e) {} }
    try { document.execCommand('styleWithCSS', false, true); } catch (e) {}
    try { document.execCommand('defaultParagraphSeparator', false, 'div'); } catch (e) {}
    function sel() { return window.getSelection(); }
    function inEd(n) { while (n) { if (n === ed) return true; n = n.parentNode; } return false; }
    function esc(s) { return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;'); }
    function changed() { report(); post('changed', 1); }

    document.addEventListener('selectionchange', function () {
      var s = sel();
      if (s.rangeCount && inEd(s.anchorNode)) { saved = s.getRangeAt(0).cloneRange(); report(); }
    });
    ed.addEventListener('input', function () { changed(); });
    ed.addEventListener('focus', function () { post('focus', true); });
    ed.addEventListener('blur', function () { post('focus', false); });

    function restore() {
      if (document.activeElement !== ed) { try { ed.focus({ preventScroll: true }); } catch (e) { ed.focus(); } }
      if (saved && inEd(saved.startContainer)) { var s = sel(); s.removeAllRanges(); s.addRange(saved); }
    }
    function anchor() {
      var s = sel();
      var n = s.rangeCount ? s.anchorNode : (saved ? saved.startContainer : null);
      if (!n || !inEd(n)) n = saved ? saved.startContainer : null;
      return n;
    }
    function closest(q) {
      var n = anchor();
      while (n && n !== ed) { if (n.nodeType === 1 && n.matches(q)) return n; n = n.parentNode; }
      return null;
    }
    function report() {
      var st = {};
      ['bold', 'italic', 'underline', 'strikeThrough', 'superscript', 'subscript',
       'insertUnorderedList', 'insertOrderedList', 'justifyLeft', 'justifyCenter', 'justifyRight', 'justifyFull']
        .forEach(function (c) { try { st[c] = document.queryCommandState(c); } catch (e) { st[c] = false; } });
      try { st.block = String(document.queryCommandValue('formatBlock') || '').toLowerCase(); } catch (e) { st.block = ''; }
      var n = anchor();
      if (n && n.nodeType === 3) n = n.parentNode;
      if (n && n.nodeType === 1) {
        var cs = getComputedStyle(n);
        st.font = cs.fontFamily; st.size = cs.fontSize; st.color = cs.color; st.bg = cs.backgroundColor;
      }
      st.inTable = !!closest('td,th');
      var a = closest('a');
      st.link = a ? (a.getAttribute('href') || '') : '';
      st.inList = !!closest('ul,ol');
      st.painter = !!painter;
      post('state', st);
    }
    function fixSize(sz) {
      ed.querySelectorAll('font[size="7"]').forEach(function (f) {
        var sp = document.createElement('span');
        sp.style.fontSize = sz;
        while (f.firstChild) sp.appendChild(f.firstChild);
        f.parentNode.replaceChild(sp, f);
      });
      ed.querySelectorAll('[style*="xxx-large"]').forEach(function (e) { e.style.fontSize = sz; });
    }
    function blocksInSel() {
      var s = sel();
      if (!s.rangeCount) return [];
      var r = s.getRangeAt(0);
      var all = ed.querySelectorAll('div,p,li,h1,h2,h3,h4,h5,h6,blockquote,pre,td,th');
      var out = [];
      for (var i = 0; i < all.length; i++) {
        var el = all[i];
        if (r.intersectsNode(el) && !el.querySelector('div,p,li,h1,h2,h3,h4,h5,h6,blockquote,pre,table')) out.push(el);
      }
      return out;
    }
    function blocks() {
      restore();
      var b = blocksInSel();
      if (!b.length) { document.execCommand('formatBlock', false, 'div'); b = blocksInSel(); }
      return b;
    }
    function cell() { return closest('td,th'); }
    function selectedCells() {
      var out = [];
      var s = sel();
      var t = closest('table');
      if (s.rangeCount && t) {
        var r = s.getRangeAt(0);
        t.querySelectorAll('td,th').forEach(function (c) { if (r.intersectsNode(c)) out.push(c); });
      }
      if (!out.length) { var c = cell(); if (c) out.push(c); }
      return out;
    }

    var RE = {
      cmd: function (c, v) {
        restore();
        document.execCommand(c, false, (v === undefined || v === null) ? null : v);
        changed();
      },
      fontSize: function (pt) {
        restore();
        document.execCommand('fontSize', false, '7');
        fixSize(pt + 'pt');
        changed();
      },
      growFont: function (delta) {
        var n = anchor(); if (n && n.nodeType === 3) n = n.parentNode;
        var px = n && n.nodeType === 1 ? parseFloat(getComputedStyle(n).fontSize) : 14.67;
        var pt = Math.round(px * 0.75 * 2) / 2 + delta;
        RE.fontSize(Math.max(6, Math.min(96, pt)));
      },
      color: function (c) { RE.cmd('foreColor', c); },
      highlight: function (c) { RE.cmd('hiliteColor', c || 'transparent'); },
      clear: function () {
        restore();
        document.execCommand('removeFormat');
        document.execCommand('formatBlock', false, 'div');
        changed();
      },
      block: function (tag) { RE.cmd('formatBlock', tag); },
      bullet: function (type) {
        restore();
        var l = closest('ul,ol');
        if (!l || l.tagName !== 'UL') { document.execCommand('insertUnorderedList'); l = closest('ul'); }
        if (l && type) l.style.listStyleType = type;
        changed();
      },
      number: function (type) {
        restore();
        var l = closest('ul,ol');
        if (!l || l.tagName !== 'OL') { document.execCommand('insertOrderedList'); l = closest('ol'); }
        if (l && type) l.style.listStyleType = type;
        changed();
      },
      lineHeight: function (v) { blocks().forEach(function (el) { el.style.lineHeight = v; }); changed(); },
      spaceAfter: function (v) { blocks().forEach(function (el) { el.style.marginTop = '0'; el.style.marginBottom = v; }); changed(); },
      link: function (url, text) {
        restore();
        var a = closest('a');
        if (a) {
          a.setAttribute('href', url);
          if (text) a.textContent = text;
        } else {
          var s = sel();
          if (s.isCollapsed || !s.toString()) {
            document.execCommand('insertHTML', false, '<a href="' + esc(url) + '">' + esc(text || url) + '</a>&nbsp;');
          } else {
            document.execCommand('createLink', false, url);
          }
        }
        changed();
      },
      unlink: function () {
        restore();
        var a = closest('a');
        if (a) {
          var r = document.createRange(); r.selectNodeContents(a);
          var s = sel(); s.removeAllRanges(); s.addRange(r);
        }
        document.execCommand('unlink');
        changed();
      },
      linkText: function () {
        var a = closest('a');
        if (a) return a.textContent;
        return saved ? saved.toString() : '';
      },
      image: function (src) {
        RE.cmd('insertHTML', '<img src="' + src + '" style="max-width:100%;height:auto">');
      },
      table: function (rows, cols, header, full, border) {
        var w = full ? 'width:100%;' : '';
        var bd = border || '1px solid #8c8c8c';
        var h = '<table style="border-collapse:collapse;' + w + '"><tbody>';
        for (var r = 0; r < rows; r++) {
          h += '<tr>';
          for (var c = 0; c < cols; c++) {
            var head = header && r === 0;
            var tag = head ? 'th' : 'td';
            var bg = head ? 'background-color:#f2f2f2;font-weight:bold;' : '';
            h += '<' + tag + ' style="border:' + bd + ';padding:4px 8px;min-width:48px;vertical-align:top;text-align:left;' + bg + '"><br></' + tag + '>';
          }
          h += '</tr>';
        }
        h += '</tbody></table><div><br></div>';
        RE.cmd('insertHTML', h);
      },
      addRow: function (after) {
        restore(); var c = cell(); if (!c) return;
        var row = c.parentNode; var nr = row.cloneNode(true);
        for (var i = 0; i < nr.cells.length; i++) { nr.cells[i].innerHTML = '<br>'; }
        row.parentNode.insertBefore(nr, after ? row.nextSibling : row);
        changed();
      },
      addCol: function (after) {
        restore(); var c = cell(); if (!c) return;
        var idx = c.cellIndex; var t = c.closest('table');
        for (var i = 0; i < t.rows.length; i++) {
          var row = t.rows[i];
          var ref = row.cells[Math.min(idx, row.cells.length - 1)];
          if (!ref) continue;
          var nc = ref.cloneNode(false); nc.innerHTML = '<br>'; nc.removeAttribute('colspan');
          row.insertBefore(nc, after ? ref.nextSibling : ref);
        }
        changed();
      },
      delRow: function () {
        restore(); var c = cell(); if (!c) return;
        var t = c.closest('table'); c.parentNode.remove();
        if (!t.rows.length) t.remove();
        changed();
      },
      delCol: function () {
        restore(); var c = cell(); if (!c) return;
        var idx = c.cellIndex; var t = c.closest('table');
        for (var i = t.rows.length - 1; i >= 0; i--) {
          var row = t.rows[i];
          if (row.cells[idx]) row.deleteCell(idx);
          if (!row.cells.length) row.remove();
        }
        if (!t.rows.length) t.remove();
        changed();
      },
      delTable: function () { restore(); var t = closest('table'); if (t) t.remove(); changed(); },
      merge: function () {
        restore(); var c = cell(); if (!c) return;
        var n = c.nextElementSibling; if (!n) return;
        c.colSpan = (c.colSpan || 1) + (n.colSpan || 1);
        if (n.textContent.trim()) c.innerHTML += ' ' + n.innerHTML;
        n.remove();
        changed();
      },
      cellFill: function (color) { restore(); selectedCells().forEach(function (c) { c.style.backgroundColor = color || ''; }); changed(); },
      border: function (style) {
        restore(); var t = closest('table'); if (!t) return;
        t.querySelectorAll('td,th').forEach(function (c) { c.style.border = style; });
        changed();
      },
      tableWidth: function (full) { restore(); var t = closest('table'); if (t) t.style.width = full ? '100%' : ''; changed(); },
      replaceAll: function (find, rep, cs) {
        if (!find) return 0;
        var re = new RegExp(find.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), cs ? 'g' : 'gi');
        var w = document.createTreeWalker(ed, NodeFilter.SHOW_TEXT, null);
        var nodes = []; while (w.nextNode()) nodes.push(w.currentNode);
        var count = 0;
        nodes.forEach(function (n) {
          var m = n.nodeValue.match(re);
          if (m) { count += m.length; n.nodeValue = n.nodeValue.replace(re, function () { return rep; }); }
        });
        if (count) changed();
        return count;
      },
      findNext: function (find, cs) {
        if (!find) return false;
        try { ed.focus(); return window.find(find, !!cs, false, true, false, false, false); } catch (e) { return false; }
      },
      changeCase: function (mode) {
        restore(); var t = sel().toString(); if (!t) return;
        var o = mode === 'upper' ? t.toUpperCase() : mode === 'lower' ? t.toLowerCase()
          : t.toLowerCase().replace(/(^|[\s(\-])\S/g, function (x) { return x.toUpperCase(); });
        document.execCommand('insertText', false, o);
        changed();
      },
      copyFormat: function () {
        restore();
        var n = anchor(); if (n && n.nodeType === 3) n = n.parentNode;
        if (!n || n.nodeType !== 1) return;
        var cs = getComputedStyle(n);
        painter = {
          b: document.queryCommandState('bold'), i: document.queryCommandState('italic'),
          u: document.queryCommandState('underline'), s: document.queryCommandState('strikeThrough'),
          font: cs.fontFamily, size: cs.fontSize, color: cs.color, bg: cs.backgroundColor
        };
        report();
      },
      pasteFormat: function () {
        if (!painter) return false;
        restore();
        if (sel().isCollapsed) return false;
        var p = painter; painter = null;
        document.execCommand('removeFormat');
        if (p.b) document.execCommand('bold');
        if (p.i) document.execCommand('italic');
        if (p.u) document.execCommand('underline');
        if (p.s) document.execCommand('strikeThrough');
        document.execCommand('fontName', false, p.font);
        document.execCommand('fontSize', false, '7'); fixSize(p.size);
        document.execCommand('foreColor', false, p.color);
        if (p.bg && p.bg !== 'rgba(0, 0, 0, 0)' && p.bg !== 'transparent') document.execCommand('hiliteColor', false, p.bg);
        changed();
        return true;
      },
      cancelPainter: function () { painter = null; report(); },
      setHTML: function (h) { ed.innerHTML = h; changed(); },
      html: function () { return ed.innerHTML; },
      text: function () { return ed.innerText; },
      selectedText: function () { return saved ? saved.toString() : ''; },
      insertHTML: function (h) { RE.cmd('insertHTML', h); },
      replaceSelection: function (h) {
        restore();
        if (sel().isCollapsed) return false;
        document.execCommand('insertHTML', false, h);
        changed();
        return true;
      },
      replaceBody: function (h) {
        var q = ed.querySelector('.re-quote');
        var sig = ed.querySelector('.re-sig');
        var stop = sig || q;
        if (stop) {
          while (ed.firstChild && ed.firstChild !== stop) ed.removeChild(ed.firstChild);
          stop.insertAdjacentHTML('beforebegin', h + '<div><br></div>');
        } else {
          ed.innerHTML = h;
        }
        changed();
      },
      setSignature: function (h) {
        var s = ed.querySelector('.re-sig');
        if (!h) { if (s) { s.remove(); changed(); } return; }
        var html = '<div class="re-sig"><div><br></div>' + h + '</div>';
        if (s) { s.outerHTML = html; }
        else {
          var q = ed.querySelector('.re-quote');
          if (q) { q.insertAdjacentHTML('beforebegin', html); } else { ed.insertAdjacentHTML('beforeend', html); }
        }
        changed();
      },
      bodyText: function () {
        var c = ed.cloneNode(true);
        var q = c.querySelector('.re-quote'); if (q) q.remove();
        var s = c.querySelector('.re-sig'); if (s) s.remove();
        return c.innerText;
      },
      focusStart: function () {
        ed.focus();
        var r = document.createRange(); r.setStart(ed, 0); r.collapse(true);
        var s = sel(); s.removeAllRanges(); s.addRange(r);
        saved = r.cloneRange();
      }
    };
    post('ready', 1);
    """#
}
