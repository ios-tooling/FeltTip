(function () {
  // Surface any uncaught JS error (incl. in event listeners) to Swift so a
  // silent failure in the bridge is diagnosable.
  window.onerror = function (msg, src, line, col) {
    try { window.webkit.messageHandlers.mdedit.postMessage({ type: 'error', message: String(msg) + ' @' + line + ':' + col }); } catch (e) {}
  };
  // Confirm the script ran AND the message bridge is reachable.
  try {
    window.webkit.messageHandlers.mdedit.postMessage({ type: 'ready', bridge: !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.mdedit) });
  } catch (e) {}
  document.body.contentEditable = 'true';
  document.body.style.outline = 'none';
  // Blocks we can't map edits inside become read-only islands, so the caret
  // can't land somewhere a keystroke would be silently vetoed.
  document.querySelectorAll('pre, table, .alert, details, .frontmatter, img, hr').forEach(function (el) {
    el.contentEditable = 'false';
  });
  // Edits awaiting their `input` event, oldest first. A QUEUE, not a slot:
  // WebKit batches multiple editing commands into one turn — typing a
  // quote both inserts it AND retroactively curls the previous quote via
  // insertReplacementText — and a single slot dropped all but the last
  // edit, desyncing the source and getting the batch rejected.
  var pendingEdits = [];
  // A structural edit or desync was posted; swallow input until the host's
  // re-render (which reinjects this script) so nothing maps from a source
  // that's about to change shape. Holds { token } while frozen; if the
  // re-render never arrives (a lifecycle bug), the armed deadline posts
  // frozenTimeout so the host resyncs — typing can never stay dead.
  var frozen = null;
  // Revision of the source the data-s stamps currently describe. Seeded by
  // the host after every load (__mdSetRev) and swap (__mdSwapContent), and
  // advanced locally each time an edit is queued together with its stamp
  // shift — so every posted message declares exactly which source revision
  // its offsets address, and the host accepts only an exact match. A
  // mismatch means resync, never a guess.
  var stampRev = 0;
  // Monotonic message counter, for ordering diagnostics on the host side.
  var seq = 0;
  // Shared stamp cache — normally installed by the scroll-sync script, which
  // loads first; defined here too so the editor script stands alone (the
  // integration-test harness injects only this script).
  if (!window.__mdStamps) {
    var stampCache = null;
    window.__mdStampsInvalidate = function () { stampCache = null; };
    window.__mdStamps = function () {
      if (!stampCache) {
        var els = Array.prototype.slice.call(document.querySelectorAll('[data-s]'));
        stampCache = { els: els, bases: els.map(function (el) { return parseInt(el.getAttribute('data-s'), 10); }) };
      }
      return stampCache;
    };
  }
  window.__mdSetRev = function (rev) {
    stampRev = rev;
    pendingEdits = [];
    frozen = null;
    composing = null;
    if (window.__mdStampsInvalidate) { window.__mdStampsInvalidate(); }
  };
  // The revision this page currently addresses — lets the host (and tests)
  // confirm a freshly rendered page is live before trusting its DOM.
  window.__mdGetRev = function () { return stampRev; };
  function freeze() {
    var token = seq;
    frozen = { token: token };
    window.setTimeout(function () {
      if (frozen && frozen.token === token) {
        try { post({ type: 'frozenTimeout', token: token }); } catch (e) {}
      }
    }, 2000);
  }
  // The host refused a structural edit it had vetoed on safety grounds (the
  // page prevented the DOM mutation, so nothing is out of sync) — thaw so
  // typing continues; the vetoed keystroke is simply a no-op.
  window.__mdUnfreeze = function (token) {
    if (frozen && frozen.token === token) { frozen = null; }
  };
  // State captured at compositionstart, reconciled at compositionend.
  var composing = null;
  installLinkOpenButtons();

  function textLength(n) {
    if (n.nodeType === 3) return n.nodeValue.length;
    var t = 0; for (var i = 0; i < n.childNodes.length; i++) t += textLength(n.childNodes[i]);
    return t;
  }
  // Characters of text inside `root` that precede position (node, offset).
  function textOffsetWithin(root, node, offset) {
    var count = 0, found = false;
    function walk(n) {
      if (found) return;
      if (n === node) {
        if (n.nodeType === 3) { count += offset; }
        else { for (var i = 0; i < offset && i < n.childNodes.length; i++) count += textLength(n.childNodes[i]); }
        found = true; return;
      }
      if (n.nodeType === 3) { count += n.nodeValue.length; return; }
      for (var i = 0; i < n.childNodes.length; i++) { walk(n.childNodes[i]); if (found) return; }
    }
    walk(root);
    return found ? count : null;
  }
  // The [data-s] run element owning a DOM position, or null.
  function spanOf(node, offset) {
    var el = node.nodeType === 3 ? node.parentNode : node;
    if (node.nodeType !== 3 && node.childNodes.length) {
      var child = node.childNodes[Math.min(offset || 0, node.childNodes.length - 1)];
      if (child) el = child.nodeType === 3 ? child.parentNode : child;
    }
    return el && el.closest ? el.closest('[data-s]') : null;
  }
  function firstTextIn(n) {
    if (n.nodeType === 3) return n;
    for (var i = 0; i < n.childNodes.length; i++) { var t = firstTextIn(n.childNodes[i]); if (t) return t; }
    return null;
  }
  function lastTextIn(n) {
    if (n.nodeType === 3) return n;
    for (var i = n.childNodes.length - 1; i >= 0; i--) { var t = lastTextIn(n.childNodes[i]); if (t) return t; }
    return null;
  }
  // Element-level positions (block-boundary target ranges: paragraph
  // merges, whole-block selections) resolve to the nearest text-node
  // position so they map to the source like any other. A child with no
  // text inside (the <br>-only caret placeholder Enter creates) anchors
  // on the child element itself — the offset arithmetic handles element
  // positions inside a stamped run.
  function normalizePosition(node, offset) {
    if (node.nodeType === 3 || !node.childNodes.length) return { node: node, offset: offset };
    var t;
    if (offset > 0) {
      var last = node.childNodes[Math.min(offset, node.childNodes.length) - 1];
      t = lastTextIn(last);
      if (t) return { node: t, offset: t.nodeValue.length };
      return { node: last, offset: last.childNodes ? last.childNodes.length : 0 };
    }
    var first = node.childNodes[Math.min(offset, node.childNodes.length - 1)];
    t = firstTextIn(first);
    if (t) return { node: t, offset: 0 };
    return { node: first, offset: 0 };
  }
  // Source offset for a DOM position, or null if it isn't inside a run.
  function sourceOffsetOf(node, offset) {
    var span = spanOf(node, offset);
    if (!span) return null;
    var base = parseInt(span.getAttribute('data-s'), 10);
    var chars = textOffsetWithin(span, node, offset);
    if (chars == null) return null;
    return base + chars;
  }
  // DOM text just before/after a position within its run. Swift verifies it
  // against the source before splicing, so a stale or drifted offset gets
  // rejected (and resynced) instead of splicing into the wrong place.
  // Trimmed so a split surrogate pair can't garble the message bridge.
  function contextBefore(node, offset) {
    var span = spanOf(node, offset);
    if (!span) return '';
    var o = textOffsetWithin(span, node, offset);
    if (o == null) return '';
    var t = span.textContent;
    var s = t.substring(Math.max(0, o - 12), o);
    if (s.length && s.charCodeAt(0) >= 0xDC00 && s.charCodeAt(0) <= 0xDFFF) s = s.substring(1);
    return plain(s);
  }
  function contextAfter(node, offset) {
    var span = spanOf(node, offset);
    if (!span) return '';
    var o = textOffsetWithin(span, node, offset);
    if (o == null) return '';
    var t = span.textContent;
    var s = t.substring(o, Math.min(t.length, o + 12));
    var last = s.length ? s.charCodeAt(s.length - 1) : 0;
    if (last >= 0xD800 && last <= 0xDBFF) s = s.substring(0, s.length - 1);
    return plain(s);
  }
  // After an in-place edit, every run at or past the edit moved by the
  // edit's length delta; keep the data-s stamps in step so the next edit
  // maps from fresh offsets instead of pre-edit geometry. Runs once per
  // keystroke, so it works from the shared stamp cache and touches only the
  // tail the binary search scopes to — not every span on the page.
  function shiftStamps(start, delta, editedSpan) {
    if (!delta) return;
    var stamps = window.__mdStamps();
    var els = stamps.els, bases = stamps.bases;
    var lo = 0, hi = bases.length;
    while (lo < hi) { var mid = (lo + hi) >> 1; if (bases[mid] < start) { lo = mid + 1; } else { hi = mid; } }
    while (lo > 0 && bases[lo - 1] >= start) { lo--; }
    for (var i = lo; i < els.length; i++) {
      var el = els[i];
      if (el === editedSpan) continue;
      var follows = bases[i] > start || (bases[i] === start && editedSpan &&
        (editedSpan.compareDocumentPosition(el) & Node.DOCUMENT_POSITION_FOLLOWING));
      if (follows) {
        bases[i] += delta;
        el.setAttribute('data-s', String(bases[i]));
      }
    }
  }
  // The host swapped in freshly rendered content (see __mdSwapContent):
  // drop any in-flight edit state — its offsets described the old DOM —
  // and re-run the per-content setup. The body's own listeners survive.
  window.__mdAfterSwap = function (rev) {
    pendingEdits = [];
    frozen = null;
    composing = null;
    if (typeof rev === 'number') { stampRev = rev; }
    document.querySelectorAll('pre, table, .alert, details, .frontmatter, img, hr').forEach(function (el) {
      el.contentEditable = 'false';
    });
    installLinkOpenButtons();
  };
  function placeCaretIn(node, offset, anchor) {
    // Re-focus the editable body: a reload (e.g. after undo) clears DOM
    // focus, so without this the caret wouldn't blink and typing wouldn't
    // resume. Only reached when the host armed a caret for the focused
    // web view, so this never steals focus from another split pane.
    // preventScroll: focusing the body otherwise scrolls to the top,
    // wiping the scroll position that was just restored.
    document.body.focus({ preventScroll: true });
    var sel = window.getSelection(), r = document.createRange();
    r.setStart(node, offset); r.collapse(true);
    sel.removeAllRanges(); sel.addRange(r);
    anchor.scrollIntoView({ block: 'nearest' });
  }
  function blockOf(el) {
    return el.closest('p, li, h1, h2, h3, h4, h5, h6, blockquote, td, th') || el;
  }
  // DOM position for a source offset, or null when no run covers it.
  function spotFor(offset) {
    var spans = document.querySelectorAll('[data-s]');
    for (var i = 0; i < spans.length; i++) {
      var base = parseInt(spans[i].getAttribute('data-s'), 10);
      var len = textLength(spans[i]);
      if (offset >= base && offset <= base + len) {
        var spot = locate(spans[i], offset - base);
        if (spot) { spot.span = spans[i]; return spot; }
      }
    }
    return null;
  }
  // Show the other pane's selection as a highlight overlay, without
  // touching this page's real selection. The ::highlight(md-mirror) rule
  // ships in the theme stylesheet (MarkdownHTMLRenderer.css(for:)), so the
  // wash color follows the theme.
  // WebKit does not repaint painted highlight regions when the
  // CSS.highlights registry mutates — a deleted mirror stays on screen
  // until something else invalidates it. Toggling a compositing layer on
  // the body forces the full repaint that flushes it.
  function repaintMirror() {
    var b = document.body;
    if (!b) { return; }
    b.style.transform = 'translateZ(0)';
    void b.offsetWidth;
    b.style.transform = '';
  }
  window.__mdMirrorSelection = function (offset, length) {
    if (!window.Highlight || !CSS.highlights) { return; }
    if (offset == null || !length) { CSS.highlights.delete('md-mirror'); repaintMirror(); return; }
    var start = spotFor(offset);
    var end = spotFor(offset + length);
    if (!start || !end) { CSS.highlights.delete('md-mirror'); repaintMirror(); return; }
    // A mirror means the OTHER pane is active — this page's leftover real
    // selection (e.g. restored by a style toggle) would read as a second
    // selection next to the mirror, so drop it while we're not focused.
    if (!document.hasFocus()) {
      var stale = window.getSelection();
      if (stale && !stale.isCollapsed) { stale.removeAllRanges(); }
    }
    var r = new Range();
    r.setStart(start.node, start.offset);
    r.setEnd(end.node, end.offset);
    CSS.highlights.set('md-mirror', new Highlight(r));
    repaintMirror();
  };
  // Report selection changes as source offsets for cross-pane mirroring;
  // only while this page is focused, so the mirror always reflects the
  // pane the user is actually working in.
  function reportSelection() {
    if (!document.hasFocus()) { return; }
    var sel = window.getSelection();
    if (!sel || !sel.rangeCount || sel.isCollapsed) { post({ type: 'selection' }); return; }
    var r = sel.getRangeAt(0);
    var startPos = normalizePosition(r.startContainer, r.startOffset);
    var endPos = normalizePosition(r.endContainer, r.endOffset);
    var start = sourceOffsetOf(startPos.node, startPos.offset);
    var end = sourceOffsetOf(endPos.node, endPos.offset);
    if (start == null || end == null || end <= start) { post({ type: 'selection' }); return; }
    post({ type: 'selection', start: start, length: end - start });
  }
  var selectionReportTimer = null;
  document.addEventListener('selectionchange', function () {
    if (selectionReportTimer) { clearTimeout(selectionReportTimer); }
    selectionReportTimer = setTimeout(function () {
      selectionReportTimer = null;
      reportSelection();
    }, 120);
  });
  // Becoming the active pane: this pane's own mirror is stale. Drop the
  // highlight synchronously — the host round trip (post → state →
  // updateNSView → evaluateJavaScript) is visibly slow — then report so
  // the host state follows. mousedown fires before focus arrives, so the
  // highlight is gone before the click even lands.
  function clearOwnMirror() {
    if (window.CSS && CSS.highlights && CSS.highlights.has('md-mirror')) {
      CSS.highlights.delete('md-mirror');
      repaintMirror();
    }
  }
  document.addEventListener('mousedown', clearOwnMirror, true);
  window.addEventListener('focus', function () {
    clearOwnMirror();
    // Deferred: during the focus event document.hasFocus() can still be
    // false, which would swallow the report inside reportSelection().
    setTimeout(reportSelection, 0);
  });
  // Restore the caret — or, with a length, the full selection (style
  // toggles keep their selection alive) — after a structural re-render.
  window.__mdPlaceCaret = function (offset, length) {
    length = length || 0;
    var start = spotFor(offset);
    if (start && length) {
      var end = spotFor(offset + length) || start;
      document.body.focus({ preventScroll: true });
      var sel = window.getSelection(), r = document.createRange();
      r.setStart(start.node, start.offset);
      r.setEnd(end.node, end.offset);
      sel.removeAllRanges(); sel.addRange(r);
      start.span.scrollIntoView({ block: 'nearest' });
      return;
    }
    if (start) {
      placeCaretIn(start.node, start.offset, start.span);
      return;
    }
    if (length) { return; }   // a selection can't restore into a void
    var spans = document.querySelectorAll('[data-s]');
    var prev = null, next = null;
    for (var i = 0; i < spans.length; i++) {
      var base = parseInt(spans[i].getAttribute('data-s'), 10);
      var len = textLength(spans[i]);
      if (base + len < offset) { prev = spans[i]; }
      if (base > offset && !next) { next = spans[i]; }
    }
    // No run covers the offset: the caret sits in markdown the renderer
    // has no text for — the empty paragraph Enter just created. Without a
    // home the caret was silently dropped and the fresh page sat at the
    // top of the document. Give the offset a stamped, empty run so the
    // caret lands there and the next keystroke maps to the right spot.
    var holder = document.createElement('span');
    holder.setAttribute('data-s', String(offset));
    holder.appendChild(document.createElement('br'));
    var prevBlock = prev ? blockOf(prev) : null;
    var nextBlock = next ? blockOf(next) : null;
    var target = null;
    // Prefer an empty block the renderer DID emit between the neighbours
    // (an empty list item renders as a bare <li>).
    if (prevBlock && prevBlock.nextElementSibling && prevBlock.nextElementSibling !== nextBlock
        && textLength(prevBlock.nextElementSibling) === 0
        && !prevBlock.nextElementSibling.hasAttribute('data-s')) {
      target = prevBlock.nextElementSibling;
    } else {
      target = document.createElement('p');
      if (prevBlock && prevBlock.parentNode) { prevBlock.insertAdjacentElement('afterend', target); }
      else if (nextBlock && nextBlock.parentNode) { nextBlock.insertAdjacentElement('beforebegin', target); }
      else { document.body.appendChild(target); }
    }
    target.insertBefore(holder, target.firstChild);
    if (window.__mdStampsInvalidate) { window.__mdStampsInvalidate(); }
    placeCaretIn(holder, 0, holder);
  };
  // DOM position for the `target`-th character inside `root`.
  function locate(root, target) {
    var count = 0, found = null;
    function walk(n) {
      if (found) return;
      if (n.nodeType === 3) {
        if (target <= count + n.nodeValue.length) { found = { node: n, offset: target - count }; return; }
        count += n.nodeValue.length;
      } else { for (var i = 0; i < n.childNodes.length; i++) { walk(n.childNodes[i]); if (found) return; } }
    }
    walk(root);
    return found;
  }
  // List-item continuation marker, or null when not in a list.
  function listItemMarker(node) {
    var el = node.nodeType === 3 ? node.parentNode : node;
    var li = el && el.closest ? el.closest('li') : null;
    if (!li) return null;
    return li.parentElement && li.parentElement.tagName === 'OL' ? '\n1. ' : '\n- ';
  }
  function post(msg) { window.webkit.messageHandlers.mdedit.postMessage(msg); }
  function installLinkOpenButtons() {
    if (!document.getElementById('md-link-open-button-style')) {
      var style = document.createElement('style');
      style.id = 'md-link-open-button-style';
      style.textContent = `
        .md-link-open-button {
          display: inline-flex;
          width: 16px;
          height: 16px;
          margin: 0 0 0 3px;
          padding: 0;
          border: 0;
          border-radius: 50%;
          vertical-align: -2px;
          align-items: center;
          justify-content: center;
          background-color: transparent;
          color: currentColor;
          cursor: pointer;
          -webkit-user-select: none;
          user-select: none;
          opacity: 0.82;
          {{LINK_ICON_CSS}}
        }
        .md-link-open-button:hover {
          opacity: 1;
          background-color: rgba(127, 127, 127, 0.12);
        }
        .md-link-open-button:focus-visible {
          outline: 2px solid currentColor;
          outline-offset: 1px;
        }
        .md-link-open-button:not(.has-symbol-icon)::before {
          content: "→";
          font-size: 13px;
          line-height: 1;
        }
        .md-link-open-button.has-symbol-icon::before {
          content: "";
          width: 14px;
          height: 14px;
          background-color: currentColor;
          -webkit-mask-image: url('{{LINK_ICON_DATA_URI}}');
          -webkit-mask-position: center;
          -webkit-mask-repeat: no-repeat;
          -webkit-mask-size: 14px 14px;
          mask-image: url('{{LINK_ICON_DATA_URI}}');
          mask-position: center;
          mask-repeat: no-repeat;
          mask-size: 14px 14px;
        }
      `;
      document.head.appendChild(style);
    }

    document.querySelectorAll('a[href]').forEach(function (link) {
      if (link.dataset.mdOpenDecorated === '1') { return; }
      if (link.closest('.md-link-open-button')) { return; }
      link.dataset.mdOpenDecorated = '1';
      var displayHref = link.href;
      if (link.href.indexOf('markerlocalres://') === 0) {
        displayHref = link.getAttribute('href') || link.href;
      }
      link.title = displayHref;

      var button = document.createElement('button');
      button.type = 'button';
      button.className = 'md-link-open-button{{LINK_ICON_CLASS}}';
      button.contentEditable = 'false';
      button.tabIndex = -1;
      button.title = displayHref;
      button.style.color = window.getComputedStyle(link).color;
      button.setAttribute('aria-label', 'Open link');
      button.setAttribute('data-href', link.href);
      button.addEventListener('mousedown', function (e) {
        e.preventDefault();
        e.stopPropagation();
      });
      button.addEventListener('click', function (e) {
        e.preventDefault();
        e.stopPropagation();
        post({ type: 'openLink', href: button.getAttribute('data-href') });
      });

      var target = link;
      var sourceRun = link.closest('[data-s]');
      if (sourceRun && sourceRun.parentNode) { target = sourceRun; }
      target.insertAdjacentElement('afterend', button);
    });
  }
  // WebKit freely swaps spaces and non-breaking spaces inside
  // contentEditable text to keep visual runs from collapsing — the DOM
  // drifts from the source by U+00A0s on almost every insertion. The
  // swap is 1:1 in UTF-16 so offsets are unaffected; normalize every
  // string that crosses the bridge so it can't fail verification.
  function plain(s) { return s ? s.replace(/\u00A0/g, ' ') : s; }
  // getTargetRanges() yields StaticRanges, whose toString() is useless
  // ("[object StaticRange]"). Build a live Range to read the replaced text.
  function rangeText(r) {
    if (r.collapsed) return '';
    try {
      var live = document.createRange();
      live.setStart(r.startContainer, r.startOffset);
      live.setEnd(r.endContainer, r.endOffset);
      return live.toString();
    } catch (e) { return ''; }
  }

  document.body.addEventListener('beforeinput', function (e) {
    // Undo/redo are owned by the host (a unified, source-level stack reached
    // via the app's Undo menu command). Block WebKit's own DOM-level history
    // so it can't desync the source or move the caret. Checked first, before
    // the range lookup, because a history beforeinput may carry no range.
    if (e.inputType === 'historyUndo' || e.inputType === 'historyRedo') { e.preventDefault(); return; }
    // While a composition is live (IME, dead keys, inline predictive
    // text), marked text sits in the DOM that the source doesn't have, so
    // no event can be mapped through offsets — not even plain insertText,
    // whose target range would be tainted by the grey prediction text.
    // Everything composition-adjacent is reconciled at compositionend by
    // diffing the whole run instead.
    if (composing || e.isComposing || e.inputType === 'insertCompositionText' || e.inputType === 'deleteCompositionText') return;
    if (frozen) { e.preventDefault(); return; }
    var ranges = e.getTargetRanges();
    var range = ranges && ranges.length ? ranges[0] : null;
    if (!range && (e.inputType === 'formatBold' || e.inputType === 'formatItalic' || e.inputType === 'formatStrikeThrough')) {
      // Formatting commands report no target ranges; they act on the
      // selection, so read it directly.
      var formatSel = window.getSelection();
      if (formatSel && formatSel.rangeCount) { range = formatSel.getRangeAt(0); }
    }
    if (!range) { e.preventDefault(); return; }
    var startPos = normalizePosition(range.startContainer, range.startOffset);
    var endPos = normalizePosition(range.endContainer, range.endOffset);
    var start = sourceOffsetOf(startPos.node, startPos.offset);
    var end = sourceOffsetOf(endPos.node, endPos.offset);
    if (start == null || end == null || end < start) { e.preventDefault(); return; }
    var type = e.inputType, expected = plain(rangeText(range));
    var startSpan = spanOf(startPos.node, startPos.offset);
    var crossRun = startSpan !== spanOf(endPos.node, endPos.offset);
    // A real selection means the user chose the range — hidden syntax
    // inside it may go. A collapsed caret (block merge) may only remove
    // whitespace; the Swift side enforces the distinction.
    var selected = !window.getSelection().isCollapsed;
    var before = contextBefore(startPos.node, startPos.offset);
    var after = contextAfter(endPos.node, endPos.offset);

    // Fast path: in-place text edits within a single run. Let the browser
    // mutate the DOM and mirror the change to the source (no reload). Edits
    // that span runs touch markdown syntax the DOM doesn't show, so they
    // take the structural route instead: splice the source (context-
    // verified) and re-render.
    if (type === 'insertText' || type === 'insertReplacementText') {
      var data = e.data;
      // Autocorrect/spelling replacements deliver their text via dataTransfer.
      if (data == null && e.dataTransfer) data = e.dataTransfer.getData('text/plain');
      if (data == null) { e.preventDefault(); return; }
      data = plain(data);
      if (crossRun) {
        e.preventDefault();
        freeze();
        post({ start: start, end: end, text: data, expected: expected, crossRun: true, selected: selected, before: before, after: after, caret: start + data.length, rev: stampRev, seq: seq++ });
        return;
      }
      queueFastEdit({ start: start, end: end, text: data, expected: expected, before: before, after: after },
                    start, data.length - (end - start), startSpan);
      return;
    }
    if (type === 'deleteContentBackward' || type === 'deleteContentForward' ||
        type === 'deleteWordBackward' || type === 'deleteWordForward' || type === 'deleteByCut') {
      if (crossRun) {
        e.preventDefault();
        freeze();
        post({ start: start, end: end, text: '', expected: expected, crossRun: true, selected: selected, before: before, after: after, caret: start, rev: stampRev, seq: seq++ });
        return;
      }
      queueFastEdit({ start: start, end: end, text: '', expected: expected, before: before, after: after },
                    start, -(end - start), startSpan);
      return;
    }

    // Structural edits: splice the source and re-render (re-stamps data-s),
    // restoring the caret. Block the browser's own DOM mutation.
    if (type === 'insertParagraph') {
      e.preventDefault();
      var marker = listItemMarker(range.startContainer) || '\n\n';
      freeze();
      post({ start: start, end: end, text: marker, expected: expected, crossRun: crossRun, before: before, after: after, caret: start + marker.length, rev: stampRev, seq: seq++ });
      return;
    }
    if (type === 'formatBold' || type === 'formatItalic' || type === 'formatStrikeThrough') {
      e.preventDefault();
      if (start === end) return;  // need a selection to wrap
      var m = type === 'formatBold' ? '**' : type === 'formatItalic' ? '*' : '~~';
      freeze();
      post({ op: 'wrap', marker: m, start: start, end: end, expected: expected, crossRun: crossRun, before: before, after: after, caret: end + 2 * m.length, rev: stampRev, seq: seq++ });
      return;
    }

    e.preventDefault();  // line breaks, paste, etc. — not yet mapped
  });
  // Queue a fast-path (in-place) edit and shift the stamps for it NOW, not
  // at the `input` drain. WebKit batches several editing commands into one
  // turn, and later commands in the batch read their span bases during
  // their own beforeinput — shifting eagerly keeps every capture in the
  // coordinates of the source as it will be once the edits ahead of it have
  // been applied, which is exactly what the sequential splices on the Swift
  // side produce. (In-span character offsets are always measured fresh from
  // the DOM; only the data-s bases need this bookkeeping.)
  function queueFastEdit(msg, start, delta, span) {
    msg.rev = stampRev;
    msg.seq = seq++;
    pendingEdits.push(msg);
    shiftStamps(start, delta, span);
    stampRev += 1;
  }
  document.body.addEventListener('input', function () {
    while (pendingEdits.length) {
      post(pendingEdits.shift());
    }
  });
  // Composition (IME, dead keys, macOS inline predictive text) can't be
  // vetoed or mapped per keystroke: marked text lives in the DOM without
  // existing in the source, and plain inserts interleave with it. Instead,
  // snapshot the run when composition starts and reconcile the whole run —
  // one verified replacement — when it ends. That covers whatever the
  // composition did: committed predictions, dead-key accents, CJK input,
  // and ordinary characters typed while a prediction was showing.
  document.body.addEventListener('compositionstart', function () {
    var sel = window.getSelection();
    var r = sel && sel.rangeCount ? sel.getRangeAt(0) : null;
    var startPos = r ? normalizePosition(r.startContainer, r.startOffset) : null;
    var endPos = r ? normalizePosition(r.endContainer, r.endOffset) : null;
    var span = startPos ? spanOf(startPos.node, startPos.offset) : null;
    var endSpan = endPos ? spanOf(endPos.node, endPos.offset) : null;
    if (!r || frozen || !span || span !== endSpan) {
      composing = { desync: true };
      return;
    }
    composing = {
      span: span,
      base: parseInt(span.getAttribute('data-s'), 10),
      beforeText: plain(span.textContent)
    };
  });
  document.body.addEventListener('compositionend', function () {
    var c = composing; composing = null;
    if (!c) return;
    if (c.desync || !c.span.isConnected) {
      // The DOM may hold composed text we couldn't map; re-render.
      freeze();
      post({ type: 'desync' });
      return;
    }
    var after = plain(c.span.textContent);
    if (after === c.beforeText) return;  // canceled, nothing changed
    post({ start: c.base, end: c.base + c.beforeText.length, text: after, expected: c.beforeText, before: '', after: '', rev: stampRev, seq: seq++ });
    shiftStamps(c.base, after.length - c.beforeText.length, c.span);
    stampRev += 1;
  });
  // Report scroll so a reload can restore the reader's place.
  window.addEventListener('scroll', function () {
    window.webkit.messageHandlers.mdedit.postMessage({ type: 'scroll', y: window.scrollY });
  }, { passive: true });
})();
