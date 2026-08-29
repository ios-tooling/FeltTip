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
  // A styled document is prose, so keep iOS' software-keyboard substitutions
  // enabled explicitly. WebKit's default for a programmatically editable body
  // is not stable across OS releases and can otherwise suppress QuickType and
  // autocorrect even though the bridge handles their replacement events.
  document.body.setAttribute('autocorrect', 'on');
  document.body.setAttribute('autocapitalize', 'sentences');
  document.body.spellcheck = true;
  document.body.style.outline = 'none';
  // Blocks we can't map edits inside become read-only islands, so the caret
  // can't land somewhere a keystroke would be silently vetoed. Tables are
  // NOT among them: cell runs carry data-s stamps like any paragraph, so
  // in-place cell edits splice normally — only the structural hazards
  // (Enter mid-row; deletes that would eat a pipe) are vetoed downstream.
  document.querySelectorAll('pre, .alert, details, .frontmatter, img, hr').forEach(function (el) {
    if (el.tagName === 'PRE' && el.querySelector('[data-s]')) return;
    el.contentEditable = 'false';
  });
  // Edits awaiting their `input` event, oldest first. A QUEUE, not a slot:
  // WebKit batches multiple editing commands into one turn — typing a
  // quote both inserts it AND retroactively curls the previous quote via
  // insertReplacementText — and a single slot dropped all but the last
  // edit, desyncing the source and getting the batch rejected.
  var pendingEdits = [];
  var pendingEditWatchdog = null;
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
  var nextPasteMatchesStyle = false;
  // Native input can arrive before a structural edit has re-rendered and
  // restored its caret. Preserve ordinary typing and single-character delete
  // commands in order, then replay them once the fresh caret is live.
  var frozenInputQueue = [];
  var frozenInputReplayTimer = null;
  // A host/test may explicitly move the caret while the previous structural
  // edit is still rendering. Attach that requested source range to the next
  // buffered command so it does not replay at the previous edit's caret.
  // Ordinary rapid typing never sets this and follows the restored caret.
  var frozenRequestedSelection = null;
  var inlineNavigationSelection = null;
  // Shared stamp cache — normally installed by the scroll-sync script, which
  // loads first; defined here too so the editor script stands alone (the
  // integration-test harness injects only this script).
  if (!window.__mdStamps) {
    var stampCache = null;
    window.__mdStampsInvalidate = function () { stampCache = null; };
    window.__mdStamps = function () {
      if (!stampCache) {
        var entries = Array.prototype.slice.call(document.querySelectorAll('[data-s]'))
          .map(function (el, index) {
            return { el: el, base: parseInt(el.getAttribute('data-s'), 10), index: index };
          });
        // Empty caret-holder runs can be appended after the visible paragraph
        // even though their source anchor precedes later rendered runs. Keep
        // the binary-search cache in source order, with DOM order as the stable
        // tie-break for runs sharing an anchor.
        entries.sort(function (a, b) { return a.base - b.base || a.index - b.index; });
        stampCache = {
          els: entries.map(function (entry) { return entry.el; }),
          bases: entries.map(function (entry) { return entry.base; })
        };
      }
      return stampCache;
    };
  }
  window.__mdSetRev = function (rev) {
    stampRev = rev;
    pendingEdits = [];
    frozen = null;
    if (frozenInputReplayTimer) { clearTimeout(frozenInputReplayTimer); }
    frozenInputReplayTimer = null;
    frozenInputQueue = [];
    frozenRequestedSelection = null;
    composing = null;
    if (window.__mdStampsInvalidate) { window.__mdStampsInvalidate(); }
  };
  // The revision this page currently addresses — lets the host (and tests)
  // confirm a freshly rendered page is live before trusting its DOM.
  window.__mdGetRev = function () { return stampRev; };
  // Whether the page is frozen awaiting a structural re-render. A structural
  // edit freezes synchronously in its own turn, so "not frozen and at the
  // current revision" is a deterministic settled-state check.
  window.__mdIsFrozen = function () { return !!frozen; };
  window.__mdRequestMatchStylePaste = function () {
    nextPasteMatchesStyle = true;
  };
  function freeze() {
    var token = seq;
    frozen = { token: token };
    frozenInputQueue = [];
    frozenRequestedSelection = null;
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
    if (frozen && frozen.token === token) {
      frozen = null;
      if (frozenInputReplayTimer) { clearTimeout(frozenInputReplayTimer); }
      frozenInputReplayTimer = null;
      frozenInputQueue = [];
      frozenRequestedSelection = null;
    }
  };
  // The host has adopted newer source (for example from the raw split pane)
  // while this DOM still renders the previous revision. Block edits until the
  // debounced patch lands; otherwise an old-page splice could overwrite the
  // host's newer full string.
  window.__mdBeginHostUpdate = function () {
    pendingEdits = [];
    composing = null;
    if (frozenInputReplayTimer) { clearTimeout(frozenInputReplayTimer); }
    frozenInputReplayTimer = null;
    frozenInputQueue = [];
    frozenRequestedSelection = null;
    frozen = { token: null, hostUpdate: true };
  };
  // State captured at compositionstart, reconciled at compositionend.
  var composing = null;
  installLinkOpenButtons();
  installListAddButtons();

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
  function isSyntheticCaretHolder(span) {
    return !!(span && textLength(span) === 0 && span.querySelector('br'));
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
  function normalizePosition(node, offset, preferForward) {
    if (node.nodeType === 3 || !node.childNodes.length) return { node: node, offset: offset };
    var t;
    // A DOM range boundary is the gap between child `offset - 1` and child
    // `offset`. Its affinity depends on which side of a selection it is:
    // starts own the following child, ends own the preceding child. WebKit
    // commonly reports a mouse selection that begins at a lazy list
    // continuation this way (LI, child index); always choosing the preceding
    // child mapped Cut to the prior line, so verification vetoed the deletion
    // even though WebKit had already copied the requested text.
    if (preferForward && offset < node.childNodes.length) {
      var next = node.childNodes[Math.max(0, offset)];
      t = firstTextIn(next);
      if (t) return { node: t, offset: 0 };
      return { node: next, offset: 0 };
    }
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
  // keystroke, so it works from the source-sorted shared stamp cache and
  // touches only the tail the binary search scopes to — not every span on the
  // page.
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
    document.querySelectorAll('pre, .alert, details, .frontmatter, img, hr').forEach(function (el) {
      el.contentEditable = 'false';
    });
    installLinkOpenButtons();
    installListAddButtons();
  };
  function replayFrozenInputAfterCaret() {
    if (!frozenInputQueue.length || frozenInputReplayTimer) return;
    // Leave the caret-placement call stack first. WebKit can reject a nested
    // editing command while it is still finalizing the restored selection.
    // Keep the timer non-null until this callback begins so later native text
    // cannot overtake the older buffered characters during that one-turn gap.
    frozenInputReplayTimer = setTimeout(function () {
      frozenInputReplayTimer = null;
      var buffered = frozenInputQueue;
      frozenInputQueue = [];
      for (var i = 0; i < buffered.length; i++) {
        var input = buffered[i];
        if (input.selection) {
          window.__mdPlaceCaret(input.selection.offset, input.selection.length);
        }
        if (input.command === 'insertText') {
          document.execCommand('insertText', false, input.text);
        } else if (input.command === 'deleteWordBackward' ||
                   input.command === 'deleteWordForward') {
          var selection = window.getSelection();
          if (selection && selection.rangeCount && selection.isCollapsed) {
            selection.modify(
              'extend',
              input.command === 'deleteWordBackward' ? 'backward' : 'forward',
              'word');
          }
          document.execCommand('delete');
        } else {
          document.execCommand(input.command);
        }
      }
    }, 0);
  }
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
    replayFrozenInputAfterCaret();
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
        // A text-less run (an empty table cell's caret home, or a leftover
        // placeholder): the span element itself is the position.
        if (len === 0) { return { node: spans[i], offset: 0, span: spans[i] }; }
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
  function reportSelection(force) {
    if (!force && !document.hasFocus()) { return; }
    var sel = window.getSelection();
    if (!sel || !sel.rangeCount) { post({ type: 'selection', rev: stampRev }); return; }
    var r = sel.getRangeAt(0);
    var startPos = normalizePosition(r.startContainer, r.startOffset, true);
    var endPos = normalizePosition(r.endContainer, r.endOffset, r.collapsed);
    var start = sourceOffsetOf(startPos.node, startPos.offset);
    var end = sourceOffsetOf(endPos.node, endPos.offset);
    if (start == null || end == null || end < start) {
      post({ type: 'selection', rev: stampRev });
      return;
    }
    post({ type: 'selection', start: start, length: end - start,
           endAtBlockStart: !r.collapsed && isVisualBlockStart(endPos.node, endPos.offset),
           syntaxStart: r.collapsed ? [] : selectedSyntaxBoundaries(r, true),
           syntaxEnd: r.collapsed ? [] : selectedSyntaxBoundaries(r, false),
           rev: stampRev });
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
  // A mode-picker click can move focus before the debounced selectionchange
  // report fires. Publish the final live range during blur while WebKit still
  // owns it, so the incoming raw/styled editor receives the exact handoff.
  window.addEventListener('blur', function () {
    if (selectionReportTimer) {
      clearTimeout(selectionReportTimer);
      selectionReportTimer = null;
    }
    reportSelection(true);
  });
  // Empty-wrapper caret homes represent invisible source syntax. A native
  // left-arrow move otherwise lands at a hidden wrapper boundary—the same
  // visual caret stop—and appears not to move. Consume that hidden stop plus
  // one real character; right-arrow already crosses the holder and following
  // visible character in one native move.
  document.body.addEventListener('keydown', function (event) {
    if ((event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') ||
        event.altKey || event.ctrlKey || event.metaKey) return;
    var home = activeInlineCaretHome();
    if (!home ||
        (!home.hasAttribute('data-md-inline-caret-source-neutral') &&
         !home.hasAttribute('data-md-inline-caret-after-empty-wrapper'))) return;
    var selection = window.getSelection();
    if (!selection || !selection.rangeCount || !selection.isCollapsed) return;
    event.preventDefault();
    if (event.shiftKey) {
      var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
      walker.currentNode = home;
      var adjacent = event.key === 'ArrowLeft'
        ? walker.previousNode() : walker.nextNode();
      while (adjacent && (home.contains(adjacent) || !adjacent.nodeValue.length)) {
        adjacent = event.key === 'ArrowLeft'
          ? walker.previousNode() : walker.nextNode();
      }
      if (adjacent) {
        selection.collapse(
          adjacent,
          event.key === 'ArrowLeft' ? adjacent.nodeValue.length : 0);
        selection.modify(
          'extend', event.key === 'ArrowLeft' ? 'backward' : 'forward', 'character');
        // Whitespace adjacent to hidden inline syntax is rendered as an
        // unstamped text node. Give just the selected visible character its
        // exact source stamp so Copy and replacement typing can address it
        // without accidentally owning the hidden wrapper delimiters.
        if (!spanOf(adjacent, 0)) {
          var navigationOffset = event.key === 'ArrowLeft'
            ? home.__mdNeutralPreviousOffset : home.__mdNeutralNextOffset;
          if (Number.isFinite(navigationOffset)) {
            var selectedRange = selection.getRangeAt(0).cloneRange();
            var navigationSpan = document.createElement('span');
            navigationSpan.setAttribute('data-s', String(navigationOffset));
            navigationSpan.setAttribute('data-md-inline-navigation', '1');
            try {
              selectedRange.surroundContents(navigationSpan);
              selection.selectAllChildren(navigationSpan);
              if (window.__mdStampsInvalidate) { window.__mdStampsInvalidate(); }
            } catch (_) {}
          }
        }
        var selectedOffset = event.key === 'ArrowLeft'
          ? home.__mdNeutralPreviousOffset : home.__mdNeutralNextOffset;
        var selectedSource = event.key === 'ArrowLeft'
          ? home.__mdNeutralPreviousCharacter : home.__mdNeutralNextCharacter;
        if (Number.isFinite(selectedOffset)) {
          inlineNavigationSelection = {
            start: selectedOffset,
            expected: plain(selection.toString()),
            sourceExpected: selectedSource || plain(selection.toString()),
            range: selection.getRangeAt(0).cloneRange()
          };
        }
      }
      return;
    }
    selection.modify('move', event.key === 'ArrowLeft' ? 'backward' : 'forward', 'character');
    if (event.key === 'ArrowLeft') {
      selection.modify('move', 'backward', 'character');
    }
  });
  // Restore the caret — or, with a length, the full selection (style
  // toggles keep their selection alive) — after a structural re-render.
  function ensureVisualBlankBefore(span, sourceOffset) {
    if (sourceOffset == null) return;
    var block = blockOf(span);
    if (!block || !block.parentNode) return;
    var previous = block.previousElementSibling;
    if (previous && previous.getAttribute('data-md-visual-blank') === String(sourceOffset)) return;
    var spacer = document.createElement('p');
    spacer.setAttribute('data-md-visual-blank', String(sourceOffset));
    var holder = document.createElement('span');
    holder.setAttribute('data-s', String(sourceOffset));
    holder.appendChild(document.createElement('br'));
    spacer.appendChild(holder);
    block.insertAdjacentElement('beforebegin', spacer);
    if (window.__mdStampsInvalidate) { window.__mdStampsInvalidate(); }
  }
  function activeInlineCaretHome() {
    var selection = window.getSelection();
    if (!selection || !selection.isCollapsed) return null;
    var node = selection && selection.anchorNode;
    var element = node && node.nodeType === 1
      ? node : node && node.parentElement;
    return element && element.closest
      ? element.closest('[data-md-inline-caret-home]') : null;
  }
  function selectedInlineCaretHome() {
    var selection = window.getSelection();
    if (!selection || !selection.rangeCount || selection.isCollapsed) return null;
    var range = selection.getRangeAt(0);
    var homes = document.querySelectorAll('[data-md-inline-caret-home]');
    for (var i = 0; i < homes.length; i++) {
      try {
        if (range.intersectsNode(homes[i])) return homes[i];
      } catch (_) {}
    }
    return null;
  }
  function currentInlineNavigationSelection() {
    var navigation = inlineNavigationSelection;
    var selection = window.getSelection();
    if (!navigation || !selection || !selection.rangeCount || selection.isCollapsed) return null;
    var liveRange = selection.getRangeAt(0);
    var sameRange = liveRange.startContainer === navigation.range.startContainer &&
      liveRange.startOffset === navigation.range.startOffset &&
      liveRange.endContainer === navigation.range.endContainer &&
      liveRange.endOffset === navigation.range.endOffset;
    return sameRange && plain(selection.toString()) === navigation.expected
      ? navigation : null;
  }
  function rangeTextWithoutInlineCaretHome(range, inlineHome) {
    var value = rangeText(range);
    var marker = inlineHome && inlineHome.firstChild;
    if (!range || !marker || marker.nodeType !== 3) return value;
    try {
      var prefix = document.createRange();
      prefix.setStart(range.startContainer, range.startOffset);
      prefix.setEnd(marker, 0);
      var markerIndex = prefix.toString().length;
      if (value.charAt(markerIndex) === '\u200B') {
        return value.slice(0, markerIndex) + value.slice(markerIndex + 1);
      }
    } catch (_) {}
    return value;
  }
  function postInlineCaretPaste(inlineHome, matchStyle) {
    if (!inlineHome) return false;
    var offset = parseInt(
      inlineHome.getAttribute('data-md-inline-caret-offset'), 10);
    if (!Number.isFinite(offset)) return false;
    var cell = inlineHome.closest && inlineHome.closest('td, th');
    freeze();
    post({ op: 'paste', matchStyle: matchStyle, inCell: !!cell,
           start: offset, end: offset, expected: '', crossRun: false,
           selected: false, endAtBlockStart: false,
           syntaxStart: [], syntaxEnd: [], blockPrefixes: [],
           before: '', after: '', rev: stampRev, seq: seq++ });
    return true;
  }
  function placeInlineCaretHome(span, offset, previousSourceCharacter, sourceNeutral,
                                neutralPreviousOffset, neutralPreviousCharacter,
                                neutralNextOffset, neutralNextCharacter,
                                neutralWrapperSource, afterSpan, afterEmptyWrapper) {
    if (!span || !span.parentNode) return false;
    var inlineHolder = document.createElement('span');
    inlineHolder.setAttribute('data-s', String(offset - 1));
    inlineHolder.setAttribute('data-md-inline-caret-home', '1');
    inlineHolder.setAttribute('data-md-inline-caret-offset', String(offset));
    if (sourceNeutral) inlineHolder.setAttribute('data-md-inline-caret-source-neutral', '1');
    if (afterEmptyWrapper) {
      inlineHolder.setAttribute('data-md-inline-caret-after-empty-wrapper', '1');
    }
    inlineHolder.__mdPreviousSourceCharacter = sourceNeutral
      ? '' : (previousSourceCharacter || '');
    inlineHolder.__mdNeutralPreviousOffset = neutralPreviousOffset;
    inlineHolder.__mdNeutralPreviousCharacter = neutralPreviousCharacter || '';
    inlineHolder.__mdNeutralNextOffset = neutralNextOffset;
    inlineHolder.__mdNeutralNextCharacter = neutralNextCharacter || '';
    inlineHolder.__mdNeutralWrapperSource = neutralWrapperSource || '';
    var inlineCaretText = document.createTextNode('\u200B');
    inlineHolder.appendChild(inlineCaretText);
    var insertionReference = afterSpan ? span.nextSibling : span;
    var nextBase = parseInt(span.getAttribute('data-s'), 10);
    // If source whitespace follows the empty wrapper, the renderer leaves it
    // as an unstamped text node before the next run. The semantic caret is
    // before that whitespace, not merely before the stamped run after it.
    if (!afterSpan && Number.isFinite(neutralNextOffset) &&
        Number.isFinite(nextBase) && neutralNextOffset < nextBase &&
        span.previousSibling && span.previousSibling.nodeType === 3) {
      insertionReference = span.previousSibling;
    }
    span.parentNode.insertBefore(inlineHolder, insertionReference);
    if (window.__mdStampsInvalidate) { window.__mdStampsInvalidate(); }
    placeCaretIn(inlineCaretText, 1, inlineHolder);
    return true;
  }
  window.__mdPlaceCaret = function (offset, length, sourceLineStart, sourceLineEnd, snapHiddenSyntax, visualBlankOffset, previousSourceCharacter, sourceNeutralCaretHome, neutralPreviousOffset, neutralPreviousCharacter, neutralNextOffset, neutralNextCharacter, neutralWrapperSource, caretAfterEmptyUnderline) {
    length = length || 0;
    if (frozen) {
      frozenRequestedSelection = { offset: offset, length: length };
    }
    // An offset immediately after an empty wrapper has no rendered character
    // of its own. `spotFor` gives that hidden boundary left affinity and snaps
    // it to the preceding run; let the dedicated exact-offset home below own
    // it. The same source spelling can be visible text inside inline code,
    // though. An exact stamped DOM position wins in that case and must keep its
    // ordinary visible-character behavior.
    var mappedStart = spotFor(offset);
    var visibleWrapperText = false;
    if (caretAfterEmptyUnderline && offset >= 7) {
      var mappedSpans = document.querySelectorAll('[data-s]');
      for (var mappedIndex = 0; mappedIndex < mappedSpans.length; mappedIndex++) {
        var mappedBase = parseInt(mappedSpans[mappedIndex].getAttribute('data-s'), 10);
        if (mappedBase <= offset - 7 &&
            mappedBase + textLength(mappedSpans[mappedIndex]) >= offset) {
          visibleWrapperText = true;
          break;
        }
      }
    }
    var useAfterEmptyUnderlineHome = caretAfterEmptyUnderline &&
      !visibleWrapperText;
    var start = useAfterEmptyUnderlineHome ? null : mappedStart;
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
      ensureVisualBlankBefore(start.span, visualBlankOffset);
      // A source line break plus indentation can collapse into an unstamped
      // whitespace node before the next stamped run. At offset zero inside
      // that run WebKit gives the caret left affinity and insertText becomes
      // a silent no-op. Give the exact source offset a zero-width inline caret
      // home; the next edit is routed by its explicit source offset, then the
      // host render removes the DOM-only zero-width character.
      var startBase = parseInt(start.span.getAttribute('data-s'), 10);
      var previousSibling = start.span.previousSibling;
      if (offset === startBase && previousSibling &&
          previousSibling.nodeType === 3 && previousSibling.nodeValue.length &&
          start.span.parentNode) {
        placeInlineCaretHome(
          start.span, offset, previousSourceCharacter, false, null, '', null, '', '');
        return;
      }
      placeCaretIn(start.node, start.offset, start.span);
      return;
    }
    if (length) { return; }   // a selection can't restore into a void
    var spans = document.querySelectorAll('[data-s]');
    var prev = null, next = null, prevEnd = null, nextBase = null;
    for (var i = 0; i < spans.length; i++) {
      var base = parseInt(spans[i].getAttribute('data-s'), 10);
      var len = textLength(spans[i]);
      if (base + len < offset) { prev = spans[i]; prevEnd = base + len; }
      if ((base > offset || (useAfterEmptyUnderlineHome && base === offset)) && !next) {
        next = spans[i]; nextBase = base;
      }
    }
    var prevBlock = prev ? blockOf(prev) : null;
    var nextBlock = next ? blockOf(next) : null;
    if (useAfterEmptyUnderlineHome && sourceLineStart != null && sourceLineEnd != null) {
      var afterNextOnLine = next && nextBase >= sourceLineStart && nextBase <= sourceLineEnd;
      var afterPrevOnLine = prev && prevEnd >= sourceLineStart && prevEnd <= sourceLineEnd;
      if (afterNextOnLine && placeInlineCaretHome(
            next, offset, '', false,
            neutralPreviousOffset, neutralPreviousCharacter,
            neutralNextOffset, neutralNextCharacter,
            '', false, true)) return;
      if (afterPrevOnLine && placeInlineCaretHome(
            prev, offset, '', false,
            neutralPreviousOffset, neutralPreviousCharacter,
            neutralNextOffset, neutralNextCharacter,
            '', true, true)) return;
    }
    // A host-restored caret can address hidden Markdown syntax rather than a
    // rendered run (undoing a Cut at the start of `**paragraph**`, for
    // example). If a real run exists on that same source line, snap to its
    // nearest edge. Treat only a genuinely empty source line as needing the
    // synthetic paragraph below; otherwise that placeholder becomes a blank
    // styled-only line even though the raw source is correct.
    if (snapHiddenSyntax && sourceLineStart != null && sourceLineEnd != null) {
      var prevOnLine = prev && prevEnd >= sourceLineStart && prevEnd <= sourceLineEnd;
      var nextOnLine = next && nextBase >= sourceLineStart && nextBase <= sourceLineEnd;
      // Empty underline markup renders no DOM node at all. Its formatter caret
      // is nevertheless a real source insertion point between <u> and </u>;
      // keep that exact offset typable instead of snapping it onto the next
      // visible run, where WebKit silently drops the first character.
      if (sourceNeutralCaretHome) {
        if (nextOnLine && placeInlineCaretHome(
              next, offset, '', true,
              neutralPreviousOffset, neutralPreviousCharacter,
              neutralNextOffset, neutralNextCharacter,
              neutralWrapperSource, false)) return;
        if (prevOnLine && placeInlineCaretHome(
              prev, offset, '', true,
              neutralPreviousOffset, neutralPreviousCharacter,
              neutralNextOffset, neutralNextCharacter,
              neutralWrapperSource, true)) return;
      }
      // With runs on both sides, the caret can intentionally sit inside an
      // empty inline construct (`Alpha<u>|</u> Tail`). Preserve the existing
      // synthetic caret home for that case so typing remains formatted.
      if (!!prevOnLine !== !!nextOnLine) {
        if (nextOnLine && (!prevOnLine || nextBase - offset <= offset - prevEnd)) {
          ensureVisualBlankBefore(next, visualBlankOffset);
          var nextText = firstTextIn(next);
          if (nextText) { placeCaretIn(nextText, 0, next); }
          else { placeCaretIn(next, 0, next); }
        } else {
          var prevText = lastTextIn(prev);
          if (prevText) { placeCaretIn(prevText, prevText.nodeValue.length, prev); }
          else { placeCaretIn(prev, prev.childNodes.length, prev); }
        }
        return;
      }
    }
    // No run covers the offset: the caret sits in markdown the renderer
    // has no text for — the empty paragraph Enter just created. Without a
    // home the caret was silently dropped and the fresh page sat at the
    // top of the document. Give the offset a stamped, empty run so the
    // caret lands there and the next keystroke maps to the right spot.
    var holder = document.createElement('span');
    holder.setAttribute('data-s', String(offset));
    holder.appendChild(document.createElement('br'));
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
    // Never leave the caret inside a surrogate pair: a host-supplied offset
    // (an undo caret hint, a diff-derived restore) can land mid-emoji, and a
    // splice made from there splits the pair — lone surrogates then mangle
    // to U+FFFD crossing the JSON bridge and poison every later
    // verification. Snap to the pair's start.
    if (found && found.node.nodeType === 3 && found.offset > 0 && found.offset < found.node.nodeValue.length) {
      var hi = found.node.nodeValue.charCodeAt(found.offset - 1);
      var lo = found.node.nodeValue.charCodeAt(found.offset);
      if (hi >= 0xD800 && hi <= 0xDBFF && lo >= 0xDC00 && lo <= 0xDFFF) { found.offset -= 1; }
    }
    return found;
  }
  // The same-column cell one row down (crossing thead → tbody), or null on
  // the last row.
  function tableCellBelow(cell) {
    var row = cell.parentNode;
    var table = cell.closest('table');
    if (!row || !table) return null;
    var rows = table.querySelectorAll('tr');
    var ri = Array.prototype.indexOf.call(rows, row);
    if (ri < 0 || ri + 1 >= rows.length) return null;
    var next = rows[ri + 1];
    var ci = Array.prototype.indexOf.call(row.children, cell);
    return next.children[Math.min(ci, next.children.length - 1)] || null;
  }
  // List-item continuation marker, or null when not in a list.
  function listItemMarker(node) {
    var el = node.nodeType === 3 ? node.parentNode : node;
    var li = el && el.closest ? el.closest('li') : null;
    if (!li) return null;
    return li.parentElement && li.parentElement.tagName === 'OL' ? '\n1. ' : '\n- ';
  }
  function directListItems(list) {
    return Array.prototype.filter.call(list.children, function (child) {
      return child.tagName === 'LI';
    });
  }
  function lastEditableRunInList(list) {
    var items = directListItems(list);
    for (var itemIndex = items.length - 1; itemIndex >= 0; itemIndex--) {
      var runs = items[itemIndex].querySelectorAll('[data-s]');
      for (var runIndex = runs.length - 1; runIndex >= 0; runIndex--) {
        if (runs[runIndex].closest('li') === items[itemIndex]) {
          return runs[runIndex];
        }
      }
    }
    return null;
  }
  function listContainingSelection() {
    var selection = window.getSelection();
    if (!selection || !selection.rangeCount) return null;
    var node = selection.getRangeAt(0).startContainer;
    var el = node.nodeType === 3 ? node.parentNode : node;
    var item = el && el.closest ? el.closest('li') : null;
    return item ? item.parentElement.closest('ul, ol') : null;
  }
  function firstVisibleEditableList() {
    var lists = document.querySelectorAll('ul, ol');
    for (var i = 0; i < lists.length; i++) {
      var rect = lists[i].getBoundingClientRect();
      if (rect.bottom > 0 && rect.top < window.innerHeight &&
          lastEditableRunInList(lists[i])) {
        return lists[i];
      }
    }
    return null;
  }
  function placeCaretAtListEnd(list) {
    var run = list && lastEditableRunInList(list);
    if (!run) return false;
    var text = lastTextIn(run);
    if (text) {
      placeCaretIn(text, text.nodeValue.length, run);
    } else {
      placeCaretIn(run, run.childNodes.length, run);
    }
    return true;
  }
  // Shared button/menu/keyboard command. A requested list wins; otherwise the
  // caret's list wins, then the first source-mapped list visible from the top.
  // Keep this on the real insertParagraph route so source verification, task
  // detection, undo, freezing, patching, and caret restoration match Return.
  window.__mdInsertListItem = function (requestedList) {
    if (frozen) return false;
    var list = requestedList || listContainingSelection() ||
      firstVisibleEditableList();
    if (!placeCaretAtListEnd(list)) return false;
    document.execCommand('insertParagraph');
    return true;
  };
  // Markdown syntax can be hidden before a block's first visible character:
  // headings/quotes, or inline openers such as `**`. Enter at that visual
  // boundary must split before the hidden prefix, not at the first run's
  // data-s offset (which would produce "# \n\nHeading"). Even when no prefix
  // exists, the hidden prefix and caret still move down together. Lists
  // deliberately keep their continuation behavior.
  function isVisualBlockStart(node, offset) {
    var el = node.nodeType === 3 ? node.parentNode : node;
    if (!el || !el.closest || el.closest('li, td, th')) return false;
    var block = el.closest('h1, h2, h3, h4, h5, h6, p');
    return !!block && textOffsetWithin(block, node, offset) === 0;
  }
  function tableCellOf(node) {
    var el = node && node.nodeType === 3 ? node.parentNode : node;
    return el && el.closest ? el.closest('td, th') : null;
  }
  function readOnlyIslandOf(node) {
    var el = node && node.nodeType === 3 ? node.parentNode : node;
    var island = el && el.closest
      ? el.closest('pre, .alert, details, .frontmatter, img, hr') : null;
    return island && island.tagName === 'PRE' && island.querySelector('[data-s]')
      ? null : island;
  }
  function selectionTouchesReadOnlyIsland() {
    var selection = window.getSelection();
    if (!selection || !selection.rangeCount || selection.isCollapsed) return false;
    var range = selection.getRangeAt(0);
    var islands = document.querySelectorAll('pre, .alert, details, .frontmatter, img, hr');
    for (var i = 0; i < islands.length; i++) {
      if (islands[i].tagName === 'PRE' && islands[i].querySelector('[data-s]')) {
        // A stamped code block is editable internally, but its hidden fences
        // still make a selection crossing the PRE boundary structurally
        // unmappable. Only a selection wholly inside this PRE may proceed.
        if (islands[i].contains(range.startContainer) &&
            islands[i].contains(range.endContainer)) continue;
      }
      try { if (range.intersectsNode(islands[i])) return true; } catch (e) {}
    }
    return false;
  }
  function deleteSelectedCodeRange(range) {
    var startPos = normalizePosition(range.startContainer, range.startOffset, true);
    var endPos = normalizePosition(range.endContainer, range.endOffset, false);
    var start = sourceOffsetOf(startPos.node, startPos.offset);
    var end = sourceOffsetOf(endPos.node, endPos.offset);
    if (start == null || end == null || end < start) return false;
    var startSpan = spanOf(startPos.node, startPos.offset);
    var endSpan = spanOf(endPos.node, endPos.offset);
    var ownsStampedRun = startSpan &&
      (!startSpan.contains(range.startContainer) ||
       !startSpan.contains(range.endContainer));
    var crossRun = startSpan !== endSpan || !!ownsStampedRun;
    freeze();
    post({ start: start, end: end, text: '', expected: plain(rangeText(range)),
           crossRun: crossRun, selected: true,
           before: contextBefore(startPos.node, startPos.offset),
           after: contextAfter(endPos.node, endPos.offset),
           syntaxStart: selectedSyntaxBoundaries(range, true),
           syntaxEnd: selectedSyntaxBoundaries(range, false),
           blockPrefixes: selectedBlockPrefixes(range),
           caret: start, rev: stampRev, seq: seq++ });
    return true;
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
  function installListAddButtons() {
    if (!document.getElementById('md-list-add-button-style')) {
      var style = document.createElement('style');
      style.id = 'md-list-add-button-style';
      style.textContent = `
        ul.md-list-with-add, ol.md-list-with-add {
          position: relative;
          padding-bottom: 28px;
        }
        .md-list-add-button {
          position: absolute;
          right: 2px;
          bottom: 2px;
          display: inline-flex;
          width: 24px;
          height: 24px;
          padding: 0;
          border: 1px solid rgba(127, 127, 127, 0.3);
          border-radius: 50%;
          align-items: center;
          justify-content: center;
          background: rgba(127, 127, 127, 0.08);
          color: currentColor;
          cursor: pointer;
          -webkit-user-select: none;
          user-select: none;
          opacity: 0.72;
        }
        .md-list-add-button:hover {
          opacity: 1;
          background: rgba(127, 127, 127, 0.16);
        }
        .md-list-add-button:focus-visible {
          outline: 2px solid currentColor;
          outline-offset: 1px;
        }
        .md-list-add-button::before {
          content: "+";
          font-size: 18px;
          font-weight: 500;
          line-height: 1;
        }
      `;
      document.head.appendChild(style);
    }
    document.querySelectorAll('ul, ol').forEach(function (list) {
      if (!lastEditableRunInList(list)) return;
      if (Array.prototype.some.call(list.children, function (child) {
        return child.classList &&
          child.classList.contains('md-list-add-button');
      })) return;
      list.classList.add('md-list-with-add');
      var button = document.createElement('button');
      button.type = 'button';
      button.className = 'md-list-add-button';
      button.contentEditable = 'false';
      button.tabIndex = -1;
      button.title = 'Add list item (⌘↩)';
      button.setAttribute('aria-label', 'Add list item');
      button.addEventListener('mousedown', function (event) {
        event.preventDefault();
        event.stopPropagation();
      });
      button.addEventListener('click', function (event) {
        event.preventDefault();
        event.stopPropagation();
        window.__mdInsertListItem(list);
      });
      list.appendChild(button);
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
  // Hidden Markdown delimiters are outside stamped text runs. When a real
  // selection owns the whole visible contents of an inline element, report
  // which syntax boundaries were selected. Deletion consumes them; nonempty
  // replacement consumes incompatible endpoints only when it crosses runs,
  // while replacement inside one styled run retains that run's formatting.
  function selectedSyntaxBoundaries(range, atStart) {
    var node = atStart ? range.startContainer : range.endContainer;
    var offset = atStart ? range.startOffset : range.endOffset;
    var element = node.nodeType === 1 ? node : node.parentElement;
    var tags = [];
    while (element && element !== document.body) {
      var tag = element.tagName ? element.tagName.toLowerCase() : '';
      var isInlineCode = tag === 'code' && !element.closest('pre');
      if (tag === 'strong' || tag === 'em' || tag === 'u' || tag === 'del' ||
          tag === 'mark' || tag === 'sup' || tag === 'sub' ||
          isInlineCode || tag === 'a') {
        var relative = textOffsetWithin(element, node, offset);
        var oppositeNode = atStart ? range.endContainer : range.startContainer;
        var oppositeOffset = atStart ? range.endOffset : range.startOffset;
        var opposite = textOffsetWithin(element, oppositeNode, oppositeOffset);
        var ownsEndpoint = relative != null &&
          (atStart ? relative === 0 : relative === textLength(element));
        // Reaching one edge is not enough while the other endpoint remains
        // inside this same inline element: replacing a prefix of **Alpha**
        // must keep both `**` delimiters around the unselected suffix. The
        // boundary is owned only when the selection exits the element or owns
        // its complete visible contents.
        var ownsOppositeEdge = opposite != null &&
          (atStart ? opposite === textLength(element) : opposite === 0);
        if (ownsEndpoint && (range.collapsed || opposite == null || ownsOppositeEdge)) {
          tags.push(tag);
        }
      }
      element = element.parentElement;
    }
    return tags;
  }
  // Metadata for the outermost inline wrapper containing a selection. A
  // multiline paste cannot remain inside that wrapper, but the host can split
  // it around the paste so unselected styled text on either side survives.
  function selectedInlineContainer(range) {
    if (!range || range.collapsed) return null;
    var node = range.startContainer;
    var element = node.nodeType === 1 ? node : node.parentElement;
    var container = null;
    while (element && element !== document.body) {
      if (isInlineSyntaxElement(element) &&
          (element === range.endContainer || element.contains(range.endContainer))) {
        container = element;
      }
      element = element.parentElement;
    }
    if (!container) return null;
    var full = document.createRange();
    full.selectNodeContents(container);
    var startPos = normalizePosition(full.startContainer, full.startOffset, true);
    var endPos = normalizePosition(full.endContainer, full.endOffset, false);
    var start = sourceOffsetOf(startPos.node, startPos.offset);
    var end = sourceOffsetOf(endPos.node, endPos.offset);
    if (start == null || end == null || end < start) return null;
    var normalized = document.createRange();
    normalized.setStart(startPos.node, startPos.offset);
    normalized.setEnd(endPos.node, endPos.offset);
    return { start: start, end: end,
             syntaxStart: selectedSyntaxBoundaries(normalized, true),
             syntaxEnd: selectedSyntaxBoundaries(normalized, false) };
  }
  function isInlineSyntaxElement(element) {
    if (!element || !element.tagName) return false;
    var tag = element.tagName.toLowerCase();
    var isInlineCode = tag === 'code' && !element.closest('pre');
    return tag === 'strong' || tag === 'em' || tag === 'u' || tag === 'del' ||
      tag === 'mark' || tag === 'sup' || tag === 'sub' || isInlineCode || tag === 'a';
  }
  // Unlike ownership metadata above, syntax invalidation cares whether an edit
  // merely TOUCHES a formatted run edge. Deleting the first character of
  // `**é a**`, for example, leaves `** a**`: the delimiters become literal even
  // though the deletion did not own the whole strong element. That operation
  // must re-render instead of retaining the old DOM styling.
  function touchesInlineSyntaxBoundary(range) {
    var positions = [
      { node: range.startContainer, offset: range.startOffset },
      { node: range.endContainer, offset: range.endOffset }
    ];
    for (var i = 0; i < positions.length; i++) {
      var position = positions[i];
      var element = position.node.nodeType === 1
        ? position.node : position.node.parentElement;
      while (element && element !== document.body) {
        if (isInlineSyntaxElement(element)) {
          var relative = textOffsetWithin(
            element, position.node, position.offset);
          var atStart = relative === 0;
          var atEnd = relative === textLength(element);
          if (atStart && atEnd) return 'inside-both';
          if (atStart) return 'inside-start';
          if (atEnd) return 'inside-end';
        }
        element = element.parentElement;
      }
      // A caret at a rendered run boundary often belongs to the neighbouring
      // plain span or to their common parent, rather than to the <strong>/<em>
      // element whose hidden delimiter it touches. Compare visible offsets in
      // the containing block so both DOM affinities identify the same syntax
      // edge.
      var owner = position.node.nodeType === 1
        ? position.node : position.node.parentElement;
      var block = owner && owner.closest
        ? owner.closest('p, li, h1, h2, h3, h4, h5, h6, blockquote, td, th') : null;
      var blockOffset = block
        ? textOffsetWithin(block, position.node, position.offset) : null;
      if (block && blockOffset != null) {
        var inlineElements = block.querySelectorAll(
          'strong, em, u, del, mark, sup, sub, code, a');
        for (var j = 0; j < inlineElements.length; j++) {
          var inlineElement = inlineElements[j];
          if (!isInlineSyntaxElement(inlineElement)) continue;
          var inlineStart = textOffsetWithin(block, inlineElement, 0);
          var inlineEnd = textOffsetWithin(
            block, inlineElement, inlineElement.childNodes.length);
          if (blockOffset === inlineStart || blockOffset === inlineEnd) return 'adjacent';
        }
      }
    }
    return '';
  }
  // A native single-run mutation is only visually complete while it cannot
  // change how Markdown parses that run. Literal delimiter characters can
  // become formatting after an insertion (`b**` → `b*a*`). Whitespace at any
  // formatted edge can invalidate its delimiter pair; a character inserted
  // from the adjacent plain run can change delimiter flanking and pair with
  // syntax elsewhere in the paragraph. Those
  // edits must splice source first and re-render instead of leaving the live
  // DOM with yesterday's interpretation.
  function needsStructuralInlineRefresh(range, replacement, before, after) {
    var nearby = before.slice(-4) + replacement + after.slice(0, 4);
    if (/[*_+~^`#=\[\]<>\\]/.test(nearby)) return true;
    var atSyntaxBoundary = touchesInlineSyntaxBoundary(range);
    // WebKit may resolve a caret at the first text position of an inline
    // wrapper to the outside DOM affinity when it performs the native mutation.
    // The target still maps to the styled stamp, so a fast edit would expect
    // text that never appears in that run and then recover by resync. The end
    // affinity is stable for an added word character after an existing word;
    // keep that common typing route fast while rebuilding every leading edge.
    if (atSyntaxBoundary === 'adjacent' || atSyntaxBoundary === 'inside-both' ||
        atSyntaxBoundary === 'inside-start') return true;
    if (atSyntaxBoundary !== 'inside-end') return false;
    var wordOnly = replacement !== '' && /^[\p{L}\p{N}\p{M}]+$/u.test(replacement);
    if (!wordOnly) return true;
    return !/^[\p{L}\p{N}\p{M}]$/u.test(before.slice(-1));
  }
  // WebKit normalizes adjacent editable spaces as it deletes. Removing one
  // space from a doubled run can remove or NBSP-rebalance more DOM text than
  // the target range describes; deleting a word between spaces can collapse
  // the two surviving spaces into one. Source intentionally preserves those
  // characters, so perform these edits structurally instead of repairing the
  // predictable DOM drift with a recovery resync afterwards.
  function needsStructuralWhitespaceDeletion(expected, before, after) {
    var onlyHorizontalWhitespace = expected !== '' && /^[ \t]+$/.test(expected);
    var deletesVisibleText = /[^ \t]/.test(expected);
    var adjacentBefore = /[ \t]$/.test(before);
    var adjacentAfter = /^[ \t]/.test(after);
    var repeatedBefore = /[ \t]{2}$/.test(before);
    var repeatedAfter = /^[ \t]{2}/.test(after);
    return (onlyHorizontalWhitespace && (adjacentBefore || adjacentAfter)) ||
      (adjacentBefore && adjacentAfter) ||
      (deletesVisibleText && (repeatedBefore || repeatedAfter)) ||
      (deletesVisibleText && adjacentBefore && after === '') ||
      (deletesVisibleText && before === '' && adjacentAfter);
  }
  function needsStructuralWhitespaceInsertion(replacement, before, after) {
    if (replacement === '') return false;
    if (/[ \t]{2}$/.test(before) || /^[ \t]{2}/.test(after)) return true;
    if (/[ \t]$/.test(before) && /^[ \t]/.test(after)) return true;
    return /^[ \t]+$/.test(replacement) &&
      (/[ \t]$/.test(before) || /^[ \t]/.test(after));
  }
  function needsStructuralBlockPrefixRefresh(range, replacement, before, after) {
    var node = range.startContainer;
    var owner = node.nodeType === 1 ? node : node.parentElement;
    var block = owner && owner.closest
      ? owner.closest('p, li, h1, h2, h3, h4, h5, h6, blockquote') : null;
    if (!block) return false;
    var offset = textOffsetWithin(block, range.startContainer, range.startOffset);
    if (offset == null) return false;
    var localBefore = before.slice(Math.max(0, before.length - offset));
    var prefix = localBefore + replacement + after.slice(0, 12);
    return /(?:^|\n)(?:\|[ \t]*:?-{3,}|(?:-[ \t]*){3,}|#{1,6}[ \t]|>[ \t]?|:(?:[ \t]|$)|(?:[-+*]|[0-9]+[.)])[ \t]+|```|~~~)/.test(prefix);
  }
  function selectedBlockPrefixes(range) {
    var node = range.startContainer;
    var element = node.nodeType === 1 ? node : node.parentElement;
    var tags = [], foundListItem = false;
    while (element && element !== document.body) {
      var ownsVisibleText = false;
      try {
        var before = document.createRange();
        before.selectNodeContents(element);
        before.setEnd(range.startContainer, range.startOffset);
        var after = document.createRange();
        after.selectNodeContents(element);
        after.setStart(range.endContainer, range.endOffset);
        ownsVisibleText = before.toString().trim() === '' && after.toString().trim() === '';
      } catch (e) {}
      if (ownsVisibleText) {
        var tag = element.tagName ? element.tagName.toLowerCase() : '';
        if (/^h[1-6]$/.test(tag)) tags.push('heading');
        else if (tag === 'li') { tags.push('list'); foundListItem = true; }
        else if ((tag === 'ul' || tag === 'ol') && !foundListItem) {
          tags.push('list');
          foundListItem = true;
        } else if (tag === 'blockquote') tags.push('blockquote');
      }
      element = element.parentElement;
    }
    return tags;
  }

  window.__mdApplyFormat = function (command) {
    if (frozen) { return false; }
    var sel = window.getSelection();
    if (!sel || !sel.rangeCount) { return false; }
    var range = sel.getRangeAt(0);
    if (selectionTouchesReadOnlyIsland()) { return false; }
    var inlineHome = activeInlineCaretHome();
    if (inlineHome && sel.isCollapsed) {
      var inlineFormatOffset = parseInt(
        inlineHome.getAttribute('data-md-inline-caret-offset'), 10);
      if (!Number.isFinite(inlineFormatOffset)) return false;
      freeze();
      post({ op: 'format', command: command,
             start: inlineFormatOffset, end: inlineFormatOffset,
             expected: '', crossRun: false, selected: false,
             endAtBlockStart: false, before: '', after: '',
             caret: inlineFormatOffset,
             rev: stampRev, seq: seq++ });
      return true;
    }
    var startPos = normalizePosition(range.startContainer, range.startOffset, true);
    var endPos = normalizePosition(range.endContainer, range.endOffset, range.collapsed);
    var start = sourceOffsetOf(startPos.node, startPos.offset);
    var end = sourceOffsetOf(endPos.node, endPos.offset);
    if (start == null || end == null || end < start) { return false; }
    var startCell = tableCellOf(startPos.node);
    var endCell = tableCellOf(endPos.node);
    var startIsland = readOnlyIslandOf(startPos.node);
    var endIsland = readOnlyIslandOf(endPos.node);
    if (startIsland || endIsland ||
        (!range.collapsed && startCell !== endCell && (startCell || endCell))) {
      return false;
    }
    var startSpan = spanOf(startPos.node, startPos.offset);
    var crossRun = startSpan !== spanOf(endPos.node, endPos.offset);
    freeze();
    post({
      op: 'format',
      command: command,
      start: start,
      end: end,
      expected: plain(range.toString()),
      crossRun: crossRun,
      selected: !sel.isCollapsed,
      endAtBlockStart: !range.collapsed && isVisualBlockStart(endPos.node, endPos.offset),
      before: contextBefore(startPos.node, startPos.offset),
      after: contextAfter(endPos.node, endPos.offset),
      caret: end,
      rev: stampRev,
      seq: seq++
    });
    return true;
  };
  window.__mdToggleInlineCode = function () {
    return window.__mdApplyFormat('inlineCode');
  };

  // At a DOM-only inline caret home macOS WebKit sends `paste` but omits the
  // `beforeinput` event that normally enters the verified source bridge. Handle
  // only that marked synthetic position here; every ordinary paste continues
  // through the native beforeinput route below.
  document.body.addEventListener('paste', function (e) {
    var navigation = currentInlineNavigationSelection();
    if (navigation && !frozen && !frozenInputReplayTimer) {
      inlineNavigationSelection = null;
      var navigationMatchStyle = nextPasteMatchesStyle;
      nextPasteMatchesStyle = false;
      freeze();
      post({ op: 'paste', matchStyle: navigationMatchStyle, inCell: false,
             start: navigation.start,
             end: navigation.start + navigation.sourceExpected.length,
             expected: navigation.sourceExpected, crossRun: false, selected: true,
             endAtBlockStart: false, syntaxStart: [], syntaxEnd: [],
             blockPrefixes: [], before: '', after: '',
             rev: stampRev, seq: seq++ });
      e.preventDefault();
      return;
    }
    var inlineHome = activeInlineCaretHome();
    if (!inlineHome || frozen || frozenInputReplayTimer) return;
    var matchStyle = nextPasteMatchesStyle;
    nextPasteMatchesStyle = false;
    if (postInlineCaretPaste(inlineHome, matchStyle)) e.preventDefault();
  });

  // A restored caret home is intentionally real DOM text so WebKit can keep a
  // typable insertion point, but it is never document content. If a later
  // Select All (or a wider mouse selection) includes that temporary span,
  // native Copy would expose its zero-width character on the system clipboard.
  // Override only that exceptional copy and keep every ordinary copy native.
  document.body.addEventListener('copy', function (e) {
    var selection = window.getSelection();
    var inlineHome = selectedInlineCaretHome();
    if (!inlineHome || !e.clipboardData) return;
    var copied = plain(selection && selection.rangeCount
      ? rangeTextWithoutInlineCaretHome(selection.getRangeAt(0), inlineHome)
      : '');
    e.clipboardData.setData('text/plain', copied);
    e.preventDefault();
  });

  // Cut needs the same clipboard cleanup, but preventing its native default
  // also suppresses WebKit's deleteByCut beforeinput. Re-emit that verified
  // source operation ourselves; the normal handler below owns the deletion,
  // syntax-boundary expansion, freeze, and caret restoration.
  document.body.addEventListener('cut', function (e) {
    var liveSelection = window.getSelection();
    var navigation = currentInlineNavigationSelection();
    if (navigation && e.clipboardData) {
      inlineNavigationSelection = null;
      e.clipboardData.setData('text/plain', navigation.expected);
      e.preventDefault();
      if (frozen || frozenInputReplayTimer) return;
      setTimeout(function () {
        if (frozen || frozenInputReplayTimer) return;
        freeze();
        post({ op: 'cut', start: navigation.start,
               end: navigation.start + navigation.sourceExpected.length,
               text: '', expected: navigation.sourceExpected,
               crossRun: false, selected: true, endAtBlockStart: false,
               syntaxStart: [], syntaxEnd: [], blockPrefixes: [],
               before: '', after: '', caret: navigation.start,
               rev: stampRev, seq: seq++ });
      }, 0);
      return;
    }
    var inlineHome = selectedInlineCaretHome();
    if (!inlineHome || !e.clipboardData) return;
    var selection = window.getSelection();
    var copied = plain(selection && selection.rangeCount
      ? rangeTextWithoutInlineCaretHome(selection.getRangeAt(0), inlineHome)
      : '');
    e.clipboardData.setData('text/plain', copied);
    e.preventDefault();
    if (frozen || frozenInputReplayTimer) return;
    // WebKit commits ClipboardEvent data after the listener returns. Let that
    // happen before the host receives the cut message, because it verifies the
    // public text before adding Marker's private exact-source flavor.
    setTimeout(function () {
      if (frozen || frozenInputReplayTimer) return;
      document.body.dispatchEvent(new InputEvent('beforeinput', {
        inputType: 'deleteByCut', bubbles: true, cancelable: true
      }));
    }, 0);
  });

  document.addEventListener('keydown', function (event) {
    // WebKit can decline the native Delete command (and AppKit emits the
    // system beep) when a mouse selection owns PRE/CODE element boundaries,
    // even though the block is content-editable. Route either physical delete
    // key through execCommand while the live selection is wholly contained in
    // one source-stamped code block. Its beforeinput event then follows the
    // same verified source splice as every other selected deletion.
    if ((event.key === 'Backspace' || event.key === 'Delete') && !event.isComposing) {
      var deleteSelection = window.getSelection();
      if (deleteSelection && deleteSelection.rangeCount && !deleteSelection.isCollapsed) {
        var deleteRange = deleteSelection.getRangeAt(0);
        var deleteStart = deleteRange.startContainer.nodeType === 1
          ? deleteRange.startContainer : deleteRange.startContainer.parentNode;
        var deletePre = deleteStart && deleteStart.closest ? deleteStart.closest('pre') : null;
        if (deletePre && deletePre.querySelector('[data-s]') &&
            deletePre.contains(deleteRange.endContainer)) {
          if (deleteSelectedCodeRange(deleteRange)) {
            event.preventDefault();
            event.stopPropagation();
            return;
          }
        }
      }
    }
    if (event.key !== 'Enter' || !event.metaKey ||
        event.shiftKey || event.altKey || event.ctrlKey) return;
    if (window.__mdInsertListItem()) {
      event.preventDefault();
      event.stopPropagation();
    }
  }, true);

  document.body.addEventListener('beforeinput', function (e) {
    // Undo/redo are owned by the host (a unified, source-level stack reached
    // via the app's Undo menu command). Block WebKit's own DOM-level history
    // so it can't desync the source or move the caret. Checked first, before
    // the range lookup, because a history beforeinput may carry no range.
    if (e.inputType === 'historyUndo' || e.inputType === 'historyRedo') { e.preventDefault(); return; }
    // Match Style belongs to exactly one native paste command. Consume the
    // request before any early-out so a refused paste cannot affect the next.
    var requestedMatchStyle = false;
    if (e.inputType === 'insertFromPaste') {
      requestedMatchStyle = nextPasteMatchesStyle;
      nextPasteMatchesStyle = false;
    }
    // While a composition is live (IME, dead keys, inline predictive
    // text), marked text sits in the DOM that the source doesn't have, so
    // no event can be mapped through offsets — not even plain insertText,
    // whose target range would be tainted by the grey prediction text.
    // Everything composition-adjacent is reconciled at compositionend by
    // diffing the whole run instead.
    if (composing || e.isComposing || e.inputType === 'insertCompositionText' || e.inputType === 'deleteCompositionText') return;
    if (frozen || frozenInputReplayTimer) {
      if ((!frozen || !frozen.hostUpdate) &&
          (e.inputType === 'insertText' || e.inputType === 'insertReplacementText')) {
        var bufferedData = e.data;
        if (bufferedData == null && e.dataTransfer) {
          bufferedData = e.dataTransfer.getData('text/plain');
        }
        if (bufferedData != null) {
          var bufferedText = plain(bufferedData);
          var lastBuffered = frozenInputQueue[frozenInputQueue.length - 1];
          if (lastBuffered && lastBuffered.command === 'insertText' &&
              frozenRequestedSelection == null) {
            lastBuffered.text += bufferedText;
          } else {
            frozenInputQueue.push({
              command: 'insertText', text: bufferedText,
              selection: frozenRequestedSelection
            });
          }
          frozenRequestedSelection = null;
        }
      } else if ((!frozen || !frozen.hostUpdate) &&
                 (e.inputType === 'deleteContentBackward' ||
                  e.inputType === 'deleteContentForward' ||
                  e.inputType === 'deleteWordBackward' ||
                  e.inputType === 'deleteWordForward')) {
        frozenInputQueue.push({
          command: e.inputType === 'deleteContentBackward' ? 'delete'
            : e.inputType === 'deleteContentForward' ? 'forwardDelete'
            : e.inputType,
          selection: frozenRequestedSelection
        });
        frozenRequestedSelection = null;
      }
      e.preventDefault();
      return;
    }
    // WebKit reports the zero-width character inside an inline caret home as
    // the replacement target, even though it is a DOM-only anchor and the
    // source selection is collapsed. Route that one synthetic position by its
    // explicit source offset so the first restored keystroke cannot disappear
    // or be rejected as an attempt to replace text the source never contained.
    var inlineHome = activeInlineCaretHome();
    if (inlineHome && inlineHome.hasAttribute('data-md-inline-caret-after-empty-wrapper') &&
        (e.inputType === 'deleteContentBackward' ||
         e.inputType === 'deleteContentForward' ||
         e.inputType === 'deleteWordBackward' ||
         e.inputType === 'deleteWordForward')) {
      e.preventDefault();
      var afterWrapperCaretOffset = parseInt(
        inlineHome.getAttribute('data-md-inline-caret-offset'), 10);
      var afterWrapperBackward = e.inputType === 'deleteContentBackward';
      var afterWrapperWordBackward = e.inputType === 'deleteWordBackward';
      var afterWrapperWordForward = e.inputType === 'deleteWordForward';
      if ((afterWrapperWordBackward || afterWrapperWordForward) &&
          Number.isFinite(afterWrapperCaretOffset)) {
        freeze();
        post({ op: 'neutralWordDelete', start: afterWrapperCaretOffset,
               backward: afterWrapperWordBackward, afterWrapper: true,
               rev: stampRev, seq: seq++ });
        return;
      }
      var afterWrapperOffset = afterWrapperBackward
        ? inlineHome.__mdNeutralPreviousOffset : inlineHome.__mdNeutralNextOffset;
      var afterWrapperCharacter = afterWrapperBackward
        ? inlineHome.__mdNeutralPreviousCharacter : inlineHome.__mdNeutralNextCharacter;
      if (Number.isFinite(afterWrapperCaretOffset) &&
          Number.isFinite(afterWrapperOffset) && afterWrapperCharacter) {
        freeze();
        post({ start: afterWrapperOffset,
               end: afterWrapperOffset + afterWrapperCharacter.length,
               text: '', expected: afterWrapperCharacter,
               before: '', after: '',
               caret: afterWrapperBackward
                 ? afterWrapperCaretOffset - afterWrapperCharacter.length
                 : afterWrapperCaretOffset,
               rev: stampRev, seq: seq++ });
      }
      return;
    }
    if (inlineHome && inlineHome.hasAttribute('data-md-inline-caret-source-neutral') &&
        (e.inputType === 'deleteContentBackward' ||
         e.inputType === 'deleteContentForward' ||
         e.inputType === 'deleteWordBackward' ||
         e.inputType === 'deleteWordForward')) {
      e.preventDefault();
      var neutralCaretOffset = parseInt(
        inlineHome.getAttribute('data-md-inline-caret-offset'), 10);
      var neutralBackward = e.inputType === 'deleteContentBackward';
      var neutralForward = e.inputType === 'deleteContentForward';
      var neutralWordBackward = e.inputType === 'deleteWordBackward';
      var neutralWordForward = e.inputType === 'deleteWordForward';
      if ((neutralWordBackward || neutralWordForward) &&
          Number.isFinite(neutralCaretOffset)) {
        freeze();
        post({ op: 'neutralWordDelete', start: neutralCaretOffset,
               backward: neutralWordBackward, rev: stampRev, seq: seq++ });
        return;
      }
      var neutralOffset = neutralBackward
        ? inlineHome.__mdNeutralPreviousOffset : inlineHome.__mdNeutralNextOffset;
      var neutralCharacter = neutralBackward
        ? inlineHome.__mdNeutralPreviousCharacter : inlineHome.__mdNeutralNextCharacter;
      if ((neutralBackward || neutralForward) && Number.isFinite(neutralCaretOffset) &&
          Number.isFinite(neutralOffset) && neutralCharacter) {
        freeze();
        post({ start: neutralOffset, end: neutralOffset + neutralCharacter.length,
               text: '', expected: neutralCharacter,
               before: '', after: '',
               caret: neutralBackward
                 ? neutralCaretOffset - neutralCharacter.length : neutralCaretOffset,
               rev: stampRev, seq: seq++ });
      }
      return;
    }
    if (e.inputType === 'deleteContentBackward' && inlineHome) {
      var hiddenPrevious = inlineHome.__mdPreviousSourceCharacter || '';
      var hiddenCaretOffset = parseInt(
        inlineHome.getAttribute('data-md-inline-caret-offset'), 10);
      if (hiddenPrevious && Number.isFinite(hiddenCaretOffset) &&
          hiddenCaretOffset >= hiddenPrevious.length) {
        e.preventDefault();
        freeze();
        post({ start: hiddenCaretOffset - hiddenPrevious.length,
               end: hiddenCaretOffset, text: '', expected: hiddenPrevious,
               before: '', after: '', caret: hiddenCaretOffset - hiddenPrevious.length,
               rev: stampRev, seq: seq++ });
        return;
      }
    }
    if (e.inputType === 'insertText') {
      var inlineHomeData = e.data;
      if (inlineHome && inlineHomeData != null) {
        var inlineHomeOffset = parseInt(
          inlineHome.getAttribute('data-md-inline-caret-offset'), 10);
        if (Number.isFinite(inlineHomeOffset)) {
          inlineHomeData = plain(inlineHomeData);
          e.preventDefault();
          freeze();
          post({ start: inlineHomeOffset, end: inlineHomeOffset,
                 text: inlineHomeData, expected: '', before: '', after: '',
                 caret: inlineHomeOffset + inlineHomeData.length,
                 rev: stampRev, seq: seq++ });
          return;
        }
      }
    }
    if (e.inputType === 'insertFromPaste' && inlineHome) {
      if (postInlineCaretPaste(inlineHome, requestedMatchStyle)) {
        e.preventDefault();
        return;
      }
    }
    if ((e.inputType === 'insertParagraph' || e.inputType === 'insertLineBreak') &&
        inlineHome) {
      var inlineBreakOffset = parseInt(
        inlineHome.getAttribute('data-md-inline-caret-offset'), 10);
      if (Number.isFinite(inlineBreakOffset)) {
        var neutralWrapper = inlineHome.__mdNeutralWrapperSource || '';
        var neutralBreak = inlineHome.hasAttribute('data-md-inline-caret-source-neutral') &&
          neutralWrapper.length > 0;
        e.preventDefault();
        if (e.inputType === 'insertLineBreak' && inlineHome.closest &&
            inlineHome.closest('td, th')) return;
        var inlineBreak = e.inputType === 'insertParagraph' ? '\n\n' : '\\\n';
        var inlineBreakStart = neutralBreak
          ? inlineBreakOffset - 3 : inlineBreakOffset;
        var inlineBreakEnd = neutralBreak
          ? inlineBreakOffset + 4 : inlineBreakOffset;
        freeze();
        post({ start: inlineBreakStart, end: inlineBreakEnd,
               text: inlineBreak, expected: neutralBreak ? neutralWrapper : '',
               crossRun: false,
               selected: false, endAtBlockStart: false,
               collapsedSyntaxEnd: [], before: '', after: '',
               caret: inlineBreakStart + inlineBreak.length,
               listBreak: false,
               blockStartBreak: e.inputType === 'insertParagraph' ? false : undefined,
               hardBreak: e.inputType === 'insertLineBreak' ? true : undefined,
               rev: stampRev, seq: seq++ });
        return;
      }
    }
    if ((e.inputType === 'formatBold' || e.inputType === 'formatItalic' ||
         e.inputType === 'formatStrikeThrough') && inlineHome) {
      var inlineFormatOffset = parseInt(
        inlineHome.getAttribute('data-md-inline-caret-offset'), 10);
      if (Number.isFinite(inlineFormatOffset)) {
        var inlineFormatMarker = e.inputType === 'formatBold' ? '**'
          : e.inputType === 'formatItalic' ? '*' : '~~';
        e.preventDefault();
        freeze();
        post({ op: 'wrap', marker: inlineFormatMarker,
               start: inlineFormatOffset, end: inlineFormatOffset,
               expected: '', crossRun: false, selected: false,
               endAtBlockStart: false, before: '', after: '',
               caret: inlineFormatOffset + 2 * inlineFormatMarker.length,
               rev: stampRev, seq: seq++ });
        return;
      }
    }
    var ranges = e.getTargetRanges();
    var range = ranges && ranges.length ? ranges[0] : null;
    if (!range && (e.inputType === 'deleteByCut' || e.inputType === 'insertFromPaste' ||
                   e.inputType === 'formatBold' ||
                   e.inputType === 'formatItalic' || e.inputType === 'formatStrikeThrough')) {
      // Cut, paste, and formatting commands can report no target ranges; they
      // act on the selection, so read it directly. Without this fallback WebKit
      // copies a selected run to the pasteboard but the source deletion is
      // vetoed, making Cut appear to do nothing — and a paste that arrives
      // without ranges is dropped in silence, which is the worse failure of the
      // two because nothing reaches the source at all.
      var commandSel = window.getSelection();
      if (commandSel && commandSel.rangeCount) { range = commandSel.getRangeAt(0); }
    }
    if (!range) { e.preventDefault(); return; }
    // Around consecutive spaces WebKit can snap an insertText StaticRange to
    // an earlier visual caret stop even though the live Selection still holds
    // the exact source-restored position. Prefer the live caret only when the
    // two positions map to different source offsets. At a formatted edge they
    // can map to the same offset with different DOM affinity; the StaticRange
    // then correctly says whether typing belongs inside or outside the wrapper.
    // Replacement text keeps its target range because autocorrect and
    // substitutions may intentionally replace text while selection is collapsed.
    if (e.inputType === 'insertText') {
      var liveInsertionSelection = window.getSelection();
      if (liveInsertionSelection && liveInsertionSelection.rangeCount &&
          !liveInsertionSelection.isCollapsed) {
        // An empty insertText used as a selection deletion can report a
        // collapsed StaticRange even though WebKit removes the live selection.
        // The live range is the operation the user actually requested.
        range = liveInsertionSelection.getRangeAt(0);
      } else if (range.collapsed && liveInsertionSelection &&
                 liveInsertionSelection.rangeCount && liveInsertionSelection.isCollapsed) {
        var liveInsertionRange = liveInsertionSelection.getRangeAt(0);
        var targetInsertionPos = normalizePosition(
          range.startContainer, range.startOffset, true);
        var liveInsertionPos = normalizePosition(
          liveInsertionRange.startContainer, liveInsertionRange.startOffset, true);
        var targetInsertionOffset = sourceOffsetOf(
          targetInsertionPos.node, targetInsertionPos.offset);
        var liveInsertionOffset = sourceOffsetOf(
          liveInsertionPos.node, liveInsertionPos.offset);
        if (targetInsertionOffset != null && liveInsertionOffset != null &&
            targetInsertionOffset !== liveInsertionOffset &&
            spanOf(targetInsertionPos.node, targetInsertionPos.offset) ===
              spanOf(liveInsertionPos.node, liveInsertionPos.offset)) {
          range = liveInsertionRange;
        }
      }
    }
    // Selection-driven commands act on the live selection. WebKit can expose
    // a stale collapsed StaticRange while the user still has an extended
    // selection; trusting that target inserts beside the selected text or
    // drops the command instead of replacing it. Keep the reported target for
    // a collapsed live caret and for insertReplacementText, whose explicit
    // autocorrect/substitution range can intentionally differ from selection.
    var selectionDrivenInput = e.inputType === 'insertFromPaste' ||
      e.inputType === 'insertParagraph' || e.inputType === 'insertLineBreak' ||
      e.inputType === 'formatBold' || e.inputType === 'formatItalic' ||
      e.inputType === 'formatStrikeThrough';
    if (selectionDrivenInput) {
      var liveCommandSelection = window.getSelection();
      if (liveCommandSelection && liveCommandSelection.rangeCount &&
          !liveCommandSelection.isCollapsed) {
        range = liveCommandSelection.getRangeAt(0);
      }
    }
    // Physical Backspace can expose a collapsed StaticRange even though the
    // live selection is extended (notably at PRE/CODE element boundaries).
    // A selected deletion acts on that live selection, just like Cut; using
    // the collapsed target would mirror a no-op while WebKit removes the DOM.
    var deleting = e.inputType === 'deleteContentBackward' ||
      e.inputType === 'deleteContentForward' ||
      e.inputType === 'deleteWordBackward' ||
      e.inputType === 'deleteWordForward' ||
      e.inputType === 'deleteByCut';
    var liveDeletionSelection = window.getSelection();
    if (deleting && liveDeletionSelection && liveDeletionSelection.rangeCount &&
        !liveDeletionSelection.isCollapsed) {
      range = liveDeletionSelection.getRangeAt(0);
    }
    // WebKit truncates a beforeinput target range at contentEditable=false
    // even when the actual selection continues into that island. Inspect the
    // live selection before trusting the shortened target range.
    if (selectionTouchesReadOnlyIsland()) { e.preventDefault(); return; }
    var startPos = normalizePosition(range.startContainer, range.startOffset, true);
    var endPos = normalizePosition(range.endContainer, range.endOffset, range.collapsed);
    var start = sourceOffsetOf(startPos.node, startPos.offset);
    var end = sourceOffsetOf(endPos.node, endPos.offset);
    if (start == null || end == null || end < start) { e.preventDefault(); return; }
    var startCell = tableCellOf(startPos.node);
    var endCell = tableCellOf(endPos.node);
    var startIsland = readOnlyIslandOf(startPos.node);
    var endIsland = readOnlyIslandOf(endPos.node);
    if (startIsland || endIsland) {
      e.preventDefault();
      return;
    }
    // A DOM range can span cells, but its source interval necessarily owns
    // the pipes between them. Letting typing, Cut, paste, or formatting use
    // that interval silently turns a row into malformed Markdown. A selection
    // touching two cells (or a cell and outside content) is an unmapped route:
    // block it before WebKit mutates the DOM and keep the page live.
    if (!range.collapsed && startCell !== endCell && (startCell || endCell)) {
      e.preventDefault();
      return;
    }
    var type = e.inputType;
    var selectedCaretHome = selectedInlineCaretHome();
    var expected = plain(selectedCaretHome
      ? rangeTextWithoutInlineCaretHome(range, selectedCaretHome)
      : rangeText(range));
    var startSpan = spanOf(startPos.node, startPos.offset);
    // A real selection means the user chose the range — hidden syntax
    // inside it may go. A collapsed caret (block merge) may only remove
    // whitespace; the Swift side enforces the distinction.
    var selected = !window.getSelection().isCollapsed;
    var endSpan = spanOf(endPos.node, endPos.offset);
    // Element-boundary selections can own the stamped run itself (for
    // example selectNodeContents(<code>)). WebKit then removes that wrapper,
    // so the in-place route cannot keep its data-s stamp alive. Treat it like
    // a cross-run structural edit and rebuild the stamped DOM from source.
    var ownsStampedRun = selected && startSpan &&
      (!startSpan.contains(range.startContainer) ||
       !startSpan.contains(range.endContainer));
    var targetOwnsStampedText = !range.collapsed && startSpan && startSpan === endSpan &&
      textOffsetWithin(startSpan, startPos.node, startPos.offset) === 0 &&
      textOffsetWithin(startSpan, endPos.node, endPos.offset) === textLength(startSpan);
    var crossRun = startSpan !== endSpan || ownsStampedRun;
    // beforeinput target ranges are non-collapsed for Backspace/Delete even
    // when the live selection is only a caret. Only a real selection gets
    // paragraph-end snapping; otherwise a block merge must keep its native
    // preceding/following affinity.
    var endAtBlockStart = selected && isVisualBlockStart(endPos.node, endPos.offset);
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
      var replacementSyntaxStart = selected
        ? selectedSyntaxBoundaries(range, true) : [];
      var replacementSyntaxEnd = selected
        ? selectedSyntaxBoundaries(range, false) : [];
      // Replacing the complete visible contents of one styled run can make
      // WebKit discard its wrapper even though both endpoints map to the same
      // stamped span. Rebuild from source so the stamp and formatting survive;
      // the host retains these delimiters for a non-cross-run replacement.
      var ownsInlineRun = replacementSyntaxStart.length > 0 ||
        replacementSyntaxEnd.length > 0;
      // The first character typed into a synthetic empty caret home can alter
      // the surrounding block parse. In particular, a holder before stripped
      // leading whitespace is a separate live <p>, but adding text before that
      // whitespace makes it part of the following source paragraph. Re-render
      // this first insertion; subsequent characters use the normal fast path.
      if (crossRun || ownsInlineRun || isSyntheticCaretHolder(startSpan) ||
          needsStructuralWhitespaceInsertion(data, before, after) ||
          needsStructuralBlockPrefixRefresh(range, data, before, after) ||
          needsStructuralInlineRefresh(range, data, before, after)) {
        var replacementBlockPrefixes = selected
          ? selectedBlockPrefixes(range) : [];
        e.preventDefault();
        freeze();
        post({ start: start, end: end, text: data, expected: expected,
               crossRun: crossRun, selected: selected,
               endAtBlockStart: endAtBlockStart,
               syntaxStart: replacementSyntaxStart,
               syntaxEnd: replacementSyntaxEnd,
               blockPrefixes: replacementBlockPrefixes,
               before: before, after: after, caret: start + data.length,
               rev: stampRev, seq: seq++ });
        return;
      }
      queueFastEdit({ start: start, end: end, text: data, expected: expected, before: before, after: after },
                    start, data.length - (end - start), startSpan);
      return;
    }
    if (type === 'deleteContentBackward' || type === 'deleteContentForward' ||
        type === 'deleteWordBackward' || type === 'deleteWordForward' || type === 'deleteByCut') {
      // Any selected deletion owns the same complete visible boundaries as
      // Cut. Without this metadata Delete/Backspace on a whole styled block
      // removes its text but leaves hidden Markdown markers such as "# " or
      // "** **" behind.
      var syntaxStart = selected
        ? selectedSyntaxBoundaries(range, true) : [];
      var syntaxEnd = selected
        ? selectedSyntaxBoundaries(range, false) : [];
      var blockPrefixes = selected
        ? selectedBlockPrefixes(range) : [];
      // A collapsed block merge can end at the first visible character of a
      // block whose opening Markdown syntax is hidden by rendering. Tell the
      // host to stop the deletion at the verified source-line start so
      // Backspace removes only the separator, not an opener such as `**`.
      var deleteEndAtBlockStart = endAtBlockStart ||
        (!selected && crossRun && isVisualBlockStart(endPos.node, endPos.offset));
      if (crossRun || targetOwnsStampedText || syntaxStart.length ||
          syntaxEnd.length || blockPrefixes.length ||
          needsStructuralWhitespaceDeletion(expected, before, after) ||
          needsStructuralBlockPrefixRefresh(range, '', before, after) ||
          needsStructuralInlineRefresh(range, '', before, after)) {
        e.preventDefault();
        freeze();
        post({ op: type === 'deleteByCut' ? 'cut' : undefined,
               start: start, end: end, text: '', expected: expected,
               crossRun: crossRun, selected: selected, before: before, after: after,
               endAtBlockStart: deleteEndAtBlockStart,
               syntaxStart: syntaxStart, syntaxEnd: syntaxEnd,
               blockPrefixes: blockPrefixes,
               caret: start, rev: stampRev, seq: seq++ });
        return;
      }
      queueFastEdit({ op: type === 'deleteByCut' ? 'cut' : undefined,
                      start: start, end: end, text: '', expected: expected, before: before, after: after },
                    start, -(end - start), startSpan);
      return;
    }

    // Structural edits: splice the source and re-render (re-stamps data-s),
    // restoring the caret. Block the browser's own DOM mutation.
    if (type === 'insertParagraph') {
      e.preventDefault();
      // Inside a table cell a paragraph break would splice "\n\n" into the
      // middle of the row and shatter the table. Move to the same column in
      // the next row instead — spreadsheet-style — landing at the end of
      // its text (or on an empty cell's caret home). On the last row, ask
      // the host to append a fresh empty row: the page can't splice that
      // itself, since stamps don't reveal where the row's line ends.
      var enterHost = range.startContainer.nodeType === 1 ? range.startContainer : range.startContainer.parentNode;
      var enterCell = enterHost && enterHost.closest ? enterHost.closest('td, th') : null;
      if (enterCell) {
        var below = tableCellBelow(enterCell);
        if (below) {
          var landing = lastTextIn(below);
          if (landing) { placeCaretIn(landing, landing.nodeValue.length, below); }
          else {
            var home = below.querySelector('[data-s]');
            if (home) { placeCaretIn(home, 0, below); }
          }
          return;
        }
        var rowEl = enterCell.parentNode;
        var rowSpan = rowEl.querySelector('[data-s]');
        if (!rowSpan) return;
        freeze();
        post({ type: 'appendTableRow', at: parseInt(rowSpan.getAttribute('data-s'), 10),
               columns: rowEl.children.length, rev: stampRev, seq: seq++ });
        return;
      }
      // In a list the continuation marker needs the item's own indentation,
      // which only the source knows (the DOM shows nesting as structure, not
      // as leading spaces) — flag it and let the splice prefix it.
      var enterPre = enterHost && enterHost.closest ? enterHost.closest('pre') : null;
      var inEditableCode = !!(enterPre && enterPre.querySelector('[data-s]'));
      var listMarker = listItemMarker(range.startContainer);
      var marker = inEditableCode ? '\n' : (listMarker || '\n\n');
      var blockStartBreak = !listMarker
        && !inEditableCode
        && isVisualBlockStart(startPos.node, startPos.offset);
      freeze();
      post({ start: start, end: end, text: marker, expected: expected,
             crossRun: crossRun, selected: selected,
             endAtBlockStart: endAtBlockStart, before: before, after: after,
             collapsedSyntaxEnd: selected ? [] : selectedSyntaxBoundaries(range, false),
             caret: start + marker.length, listBreak: !!listMarker,
             blockStartBreak: blockStartBreak,
             rev: stampRev, seq: seq++ });
      return;
    }
    // Paste: take the plain text only (markdown IS the rich form here) and
    // splice it through the verified structural route, so a multi-line paste
    // re-renders into real blocks instead of leaving pasted markup in the DOM
    // that the source doesn't have.
    // Paste: report the range and let the host read the clipboard. WebKit
    // sanitizes the plain-text flavor on a paste's dataTransfer — a multi-line
    // paste arrives here with its newlines already stripped — so the pasteboard
    // itself is the only faithful source. Markdown IS the rich form, so plain
    // text is all we ever want.
    if (type === 'insertFromPaste') {
      e.preventDefault();
      var pasteHost = startPos.node.nodeType === 1 ? startPos.node : startPos.node.parentNode;
      var inCell = !!(pasteHost && pasteHost.closest && pasteHost.closest('td, th'));
      // Replacing a real selection owns the same complete visible formatting
      // boundaries as Delete/Cut. Include their hidden source syntax so a
      // cross-run paste cannot leave unmatched delimiters behind.
      var pasteSyntaxStart = selected
        ? selectedSyntaxBoundaries(range, true) : [];
      var pasteSyntaxEnd = selected
        ? selectedSyntaxBoundaries(range, false) : [];
      var pasteBlockPrefixes = selected
        ? selectedBlockPrefixes(range) : [];
      var pasteInlineContainer = selected
        ? selectedInlineContainer(range) : null;
      freeze();
      post({ op: 'paste', matchStyle: requestedMatchStyle, inCell: inCell,
             start: start, end: end, expected: expected,
             crossRun: crossRun, selected: selected,
             endAtBlockStart: endAtBlockStart,
             syntaxStart: pasteSyntaxStart, syntaxEnd: pasteSyntaxEnd,
             blockPrefixes: pasteBlockPrefixes,
             inlineContainer: pasteInlineContainer,
             before: before, after: after, rev: stampRev, seq: seq++ });
      return;
    }
    // Shift-Enter: a hard break inside the paragraph. Written as a backslash
    // break rather than two trailing spaces — invisible trailing whitespace
    // makes the run it ends non-verbatim, which costs it its data-s stamp and
    // leaves that text uneditable.
    if (type === 'insertLineBreak') {
      e.preventDefault();
      var breakHost = startPos.node.nodeType === 1 ? startPos.node : startPos.node.parentNode;
      if (breakHost && breakHost.closest && breakHost.closest('td, th')) { return; }
      var hardBreak = '\\\n';
      freeze();
      post({ start: start, end: end, text: hardBreak, expected: expected, crossRun: crossRun, selected: selected, endAtBlockStart: endAtBlockStart, before: before, after: after, caret: start + hardBreak.length, hardBreak: true, rev: stampRev, seq: seq++ });
      return;
    }
    if (type === 'formatBold' || type === 'formatItalic' || type === 'formatStrikeThrough') {
      e.preventDefault();
      if (start === end) return;  // need a selection to wrap
      var m = type === 'formatBold' ? '**' : type === 'formatItalic' ? '*' : '~~';
      freeze();
      post({ op: 'wrap', marker: m, start: start, end: end, expected: expected, crossRun: crossRun, selected: selected, endAtBlockStart: endAtBlockStart, before: before, after: after, caret: end + 2 * m.length, rev: stampRev, seq: seq++ });
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
    // What this run's text must read once WebKit applies the edit. The browser
    // is trusted to mutate the DOM on the fast path, and it does not always
    // mutate it the way the edit described: iOS WebKit rebalances whitespace
    // around a deletion, so deleting "alpha bravo" out of "Zero alpha bravo
    // omega" leaves the source with two spaces and the DOM with one. That
    // silently breaks the stamp invariant, and every later offset in the run
    // is short by the difference. Captured before shiftStamps, which rewrites
    // the base this is measured from.
    var base = parseInt(span.getAttribute('data-s'), 10);
    var current = span.textContent;
    msg.__span = span;
    msg.__expect = current.slice(0, msg.start - base) + msg.text +
                   current.slice(msg.end - base);
    pendingEdits.push(msg);
    shiftStamps(start, delta, span);
    stampRev += 1;
    // A permitted beforeinput should always be followed by input after WebKit
    // mutates the DOM. Alternate responder/script routes can violate that
    // pairing. Never let their abandoned edit and eagerly shifted stamps leak
    // into the next real keystroke: give the current turn a chance to deliver
    // input, then force a clean source render if it did not.
    if (!pendingEditWatchdog) {
      pendingEditWatchdog = setTimeout(function () {
        pendingEditWatchdog = null;
        if (!pendingEdits.length) return;
        pendingEdits = [];
        freeze();
        post({ type: 'desync' });
      }, 0);
    }
  }
  document.body.addEventListener('input', function () {
    if (pendingEditWatchdog) {
      clearTimeout(pendingEditWatchdog);
      pendingEditWatchdog = null;
    }
    if (!pendingEdits.length) return;
    // Only the last edit per run describes the DOM as it now stands; earlier
    // ones in a batch describe intermediate states that have already been
    // superseded.
    var finalText = new Map();
    for (var i = 0; i < pendingEdits.length; i++) {
      finalText.set(pendingEdits[i].__span, pendingEdits[i].__expect);
    }
    var drifted = false;
    var driftDetails = [];
    finalText.forEach(function (expect, span) {
      // Exact, deliberately. A looser rule that let the run show a prefix of
      // what was asked for was tried and is wrong: deleting up to a trailing
      // space leaves the DOM one character short of the source *before* the
      // caret, so the next keystroke lands early — the DOM looks like a
      // healthy prefix while the mapping is already broken. plain() keeps
      // WebKit's routine &nbsp;-for-space substitution out of it; a dropped
      // character survives that normalization, which is the point.
      if (!span.isConnected || plain(span.textContent) !== plain(expect)) {
        drifted = true;
        if (driftDetails.length < 3) {
          driftDetails.push({
            stamp: span.getAttribute('data-s'), connected: span.isConnected,
            expected: plain(expect), actual: plain(span.textContent)
          });
        }
      }
    });
    // The edits themselves are still correct — they describe what the user
    // asked for, and the host verifies each against the source before
    // splicing. It is only the DOM that can no longer be trusted, so the
    // edits go out as usual and a re-render follows to rebuild it from the
    // spliced source. Dropping them instead would lose the user's edit.
    var caret = null;
    while (pendingEdits.length) {
      var edit = pendingEdits.shift();
      caret = edit.start + edit.text.length;
      delete edit.__span;
      delete edit.__expect;
      post(edit);
    }
    if (drifted) {
      freeze();
      post({ type: 'desync', caret: caret, detail: driftDetails });
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
    var startPos = r ? normalizePosition(r.startContainer, r.startOffset, true) : null;
    var endPos = r ? normalizePosition(r.endContainer, r.endOffset, r.collapsed) : null;
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
    // A composition can change Markdown interpretation just as ordinary
    // typing can (`b**` → `b*a*`), but its marked-text mutations have already
    // happened by compositionend and cannot be classified per keystroke.
    // Always reconcile the verified whole run structurally so the committed
    // source and rendered traits converge.
    freeze();
    post({ start: c.base, end: c.base + c.beforeText.length, text: after,
           expected: c.beforeText, before: '', after: '',
           caret: c.base + after.length, rev: stampRev, seq: seq++ });
  });
})();
