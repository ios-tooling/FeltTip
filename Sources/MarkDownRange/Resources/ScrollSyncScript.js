(function () {
  if (window.__mdScrollSyncInstalled) { return; }
  window.__mdScrollSyncInstalled = true;
  // Scroll height is stable during ordinary scrolling, but reading it can
  // force WebKit to flush layout. Cache dimensions across scroll frames and
  // invalidate only when viewport/content geometry actually changes.
  var dimensions = null;
  function invalidateDimensions() { dimensions = null; }
  function scrollDimensions() {
    if (!dimensions) {
      var height = Math.max(document.documentElement.scrollHeight, document.body.scrollHeight, 1);
      var visible = window.innerHeight;
      dimensions = { height: height, visible: visible, maxY: Math.max(height - visible, 0) };
    }
    return dimensions;
  }
  function docHeight() {
    return scrollDimensions().height;
  }
  window.addEventListener('resize', invalidateDimensions, { passive: true });
  if (window.ResizeObserver) {
    var geometryObserver = new ResizeObserver(invalidateDimensions);
    geometryObserver.observe(document.documentElement);
    geometryObserver.observe(document.body);
  }
  // While a host-driven scroll is in flight, its echo must not report as
  // a user scroll — in a split view that echo claims scroll-sourcehood
  // and yanks the pane the user is actually scrolling. The echo is
  // consumed when the position settles at the target (or after a grace
  // period, if the user interrupted the drive).
  var driven = null;
  function report() {
    var dims = scrollDimensions();
    var h = dims.height;
    var vis = dims.visible;
    var y = window.scrollY || window.pageYOffset || 0;
    if (driven) {
      if (Math.abs(y - driven.y) < 3) {
        // At the driven position: this and any repeat events are echoes.
        // Stay armed — WebKit re-fires at a pinned position (e.g. clamped
        // at the bottom), and one leaked echo re-claims scroll-sourcehood.
        driven.settled = true;
        return;
      }
      if (driven.settled || Date.now() > driven.until) { driven = null; }
      else { return; }   // still converging on the target
    }
    // `top` is the fraction of the SCROLLABLE range (offset / (content −
    // viewport)), matching MarkdownTextEditor's convention on both its
    // report and apply sides — full-height fractions max out below 1.0
    // and leave the synced pane short of the bottom.
    var maxY = dims.maxY;
    var top = maxY > 0 ? Math.max(0, Math.min(1, y / maxY)) : 0;
    var visible = Math.max(0, Math.min(1, vis / h));
    var content = vis > 0 ? Math.min(1, h / vis) : 1;
    try {
      window.webkit.messageHandlers.mdedit.postMessage({ type: 'scroll', y: y, top: top, visible: visible, content: content });
    } catch (e) {}
  }
  var ticking = false;
  window.addEventListener('scroll', function () {
    if (ticking) { return; }
    ticking = true;
    window.requestAnimationFrame(function () { ticking = false; report(); });
  }, { passive: true });
  window.__mdScrollToFraction = function (f) {
    var maxY = scrollDimensions().maxY;
    // Top-anchored fraction of the scrollable range — the same units
    // report() emits, so a drive→echo round trip is the identity and the
    // panes agree at both ends of the document.
    var y = Math.max(0, Math.min(1, f)) * maxY;
    driven = { y: y, until: Date.now() + 500 };
    window.scrollTo(0, y);
  };
  window.__mdScrollByPixels = function (dy) {
    var target = Math.max(0, (window.scrollY || 0) + dy);
    driven = { y: target, until: Date.now() + 500 };
    window.scrollBy(0, dy);
  };
  // Scroll the run rendering a source offset into view (outline
  // navigation). Heading offsets point at their `#` markers, which no run
  // covers, so target the first run ending at or after the offset.
  window.__mdScrollToSourceOffset = function (offset) {
    var spans = document.querySelectorAll('[data-s]');
    var best = null;
    for (var i = 0; i < spans.length; i++) {
      var base = parseInt(spans[i].getAttribute('data-s'), 10);
      if (base + spans[i].textContent.length >= offset) { best = spans[i]; break; }
    }
    if (!best && spans.length) { best = spans[spans.length - 1]; }
    if (!best) { return; }
    var maxY = Math.max(docHeight() - window.innerHeight, 0);
    var y = Math.max(0, Math.min(maxY, best.getBoundingClientRect().top + window.scrollY - 12));
    driven = { y: y, until: Date.now() + 500 };
    window.scrollTo(0, y);
  };
  // Restore a scroll position on a freshly loaded page, then optionally
  // place the caret. Straight scrollTo at didFinish clamps to zero — the
  // content hasn't laid out yet — so retry until the page is tall enough
  // (or a deadline passes), and only then let the caret nudge the view.
  window.__mdRestoreScrollThenCaret = function (y, caret, length, sourceLineStart, sourceLineEnd, snapHiddenSyntax, visualBlankOffset) {
    var deadline = Date.now() + 1000;
    function attempt() {
      var maxY = Math.max(document.documentElement.scrollHeight, document.body.scrollHeight) - window.innerHeight;
      if (maxY >= y || Date.now() > deadline) {
        var target = Math.min(y, Math.max(maxY, 0));
        driven = { y: target, until: Date.now() + 500 };
        window.scrollTo(0, target);
        if (caret != null && window.__mdPlaceCaret) {
          window.__mdPlaceCaret(caret, length || 0, sourceLineStart, sourceLineEnd, snapHiddenSyntax, visualBlankOffset);
        }
      } else {
        // setTimeout, not requestAnimationFrame: rAF doesn't run in
        // occluded windows, and the restore must not depend on visibility.
        window.setTimeout(attempt, 16);
      }
    }
    attempt();
  };
  // In-place content update from the host (debounced re-render while the
  // user types in the other pane of a split). Swapping the body avoids a
  // navigation — no blank flash, scroll position preserved. The editor
  // page re-arms its per-content state via __mdAfterSwap.
  // Cached [data-s] runs — elements plus parsed numeric bases, in document
  // order (the renderer emits ascending source offsets). Rebuilt lazily after
  // invalidation so per-keystroke and per-marker work stops paying a full
  // querySelectorAll + parseInt walk over the whole document.
  var stampCache = null;
  window.__mdStampsInvalidate = function () { stampCache = null; };
  window.__mdStamps = function () {
    if (!stampCache) {
      var els = Array.prototype.slice.call(document.querySelectorAll('[data-s]'));
      stampCache = { els: els, bases: els.map(function (el) { return parseInt(el.getAttribute('data-s'), 10); }) };
    }
    return stampCache;
  };
  // First index whose base is >= offset (with a small backward scan so a
  // locally out-of-order entry can't hide an overlapping run).
  function stampLowerBound(bases, offset) {
    var lo = 0, hi = bases.length;
    while (lo < hi) { var mid = (lo + hi) >> 1; if (bases[mid] < offset) { lo = mid + 1; } else { hi = mid; } }
    while (lo > 0 && bases[lo - 1] >= offset) { lo--; }
    return lo;
  }
  window.__mdSwapContent = function (html, rev) {
    document.body.innerHTML = html;
    invalidateDimensions();
    window.__mdStampsInvalidate();
    if (window.__mdAfterSwap) { window.__mdAfterSwap(rev); }
    drawChangeMarkers();
  };
  // Replace a contiguous run of top-level blocks in place — the incremental
  // path for structural edits and split-pane refreshes. Returns false (and
  // touches nothing) when the live DOM doesn't look like the page the patch
  // was computed against — caret holder paragraphs, unexpected structure —
  // in which case the host falls back to a full swap/reload.
  window.__mdPatchBlocks = function (start, removeCount, htmlArray, tailAnchorOffset, tailAnchorStamp, tailEndAnchorOffset, tailEndAnchorStamp, tailSourceDelta, tailSourceBoundary, expectedOldCount, rev) {
    var blocks = Array.prototype.filter.call(document.body.children, function (el) {
      return !el.classList.contains('mdr-change-marker');
    });
    if (blocks.length !== expectedOldCount) { return false; }
    if (start + removeCount > blocks.length) { return false; }
    // Structural edits use their exact source delta when the whole surviving
    // tail lies on one side of the old edit boundary. Host-driven patches use
    // fresh-render anchors instead. All decisions read LIVE stamps because
    // fast-path typing can leave the host's fragment baseline stale.
    var tail = blocks.slice(start + removeCount);
    var delta = 0;
    if (tailSourceDelta != null) {
      var firstLiveStamp = null, lastLiveStamp = null;
      tail.forEach(function (block) {
        var stamped = block.hasAttribute('data-s') ? [block] : [];
        stamped = stamped.concat(Array.from(block.querySelectorAll('[data-s]')));
        stamped.forEach(function (element) {
          var stamp = parseInt(element.getAttribute('data-s'), 10);
          if (firstLiveStamp == null) { firstLiveStamp = stamp; }
          lastLiveStamp = stamp;
        });
      });
      if (firstLiveStamp != null && firstLiveStamp < tailSourceBoundary &&
          lastLiveStamp >= tailSourceBoundary) {
        return false;
      }
      delta = firstLiveStamp != null && firstLiveStamp >= tailSourceBoundary
        ? tailSourceDelta : 0;
    } else if (tailAnchorOffset >= 0) {
      var anchorEl = tail[tailAnchorOffset];
      var firstStamped = anchorEl
        ? (anchorEl.hasAttribute('data-s') ? anchorEl : anchorEl.querySelector('[data-s]'))
        : null;
      if (!firstStamped) { return false; }
      delta = tailAnchorStamp - parseInt(firstStamped.getAttribute('data-s'), 10);
      var endAnchorEl = tail[tailEndAnchorOffset];
      var endStamped = endAnchorEl
        ? (endAnchorEl.hasAttribute('data-s') ? endAnchorEl : endAnchorEl.querySelector('[data-s]'))
        : null;
      if (!endStamped ||
          tailEndAnchorStamp - parseInt(endStamped.getAttribute('data-s'), 10) !== delta) {
        return false;
      }
    }
    // All validation precedes mutation: a refused patch must leave a pristine
    // old DOM for the coordinator's full-swap fallback.
    for (var i = 0; i < removeCount; i++) { blocks[start + i].remove(); }
    var anchor = start + removeCount < blocks.length ? blocks[start + removeCount] : null;
    var tpl = document.createElement('template');
    tpl.innerHTML = htmlArray.join('');
    document.body.insertBefore(tpl.content, anchor);
    invalidateDimensions();
    if (tailAnchorOffset >= 0) {
      if (delta) {
        tail.forEach(function (block) {
          if (block.hasAttribute('data-s')) {
            block.setAttribute('data-s', String(parseInt(block.getAttribute('data-s'), 10) + delta));
          }
          block.querySelectorAll('[data-s]').forEach(function (el) {
            el.setAttribute('data-s', String(parseInt(el.getAttribute('data-s'), 10) + delta));
          });
        });
      }
    }
    window.__mdStampsInvalidate();
    if (window.__mdAfterSwap) { window.__mdAfterSwap(rev); }
    drawChangeMarkers();
    return true;
  };
  // Host-supplied change indicators (a git diff against the committed
  // version): a colored bar down the page's left edge beside each changed
  // run, red ticks where lines were deleted. Positions come from the
  // `data-s` source stamps, so markers are re-drawn whenever the DOM or
  // layout changes under them.
  var changeState = null;
  function clearChangeMarkers() {
    document.querySelectorAll('.mdr-change-marker').forEach(function (el) { el.remove(); });
  }
  function drawChangeMarkers() {
    clearChangeMarkers();
    if (!changeState) { return; }
    var stamps = window.__mdStamps();
    var els = stamps.els, bases = stamps.bases;
    if (!els.length) { return; }
    function place(cls, top, height, color, left, width) {
      var bar = document.createElement('div');
      bar.className = 'mdr-change-marker';
      bar.style.cssText = 'position:absolute;pointer-events:none;z-index:9;border-radius:1.5px;'
        + 'left:' + left + 'px;width:' + width + 'px;top:' + top + 'px;height:' + height + 'px;background:' + color + ';';
      document.body.appendChild(bar);
    }
    changeState.ranges.forEach(function (range) {
      // Union the vertical extents of the runs overlapping [s, e) — only
      // the runs the binary search scopes to, not every span on the page
      // (each rect read forces layout).
      var top = null, bottom = null;
      var start = Math.max(0, stampLowerBound(bases, range.s) - 1);
      for (var i = start; i < els.length; i++) {
        if (bases[i] >= range.e) { break; }
        if (bases[i] + els[i].textContent.length <= range.s) { continue; }
        var r = els[i].getBoundingClientRect();
        if (r.height <= 0) { continue; }
        var t = r.top + window.scrollY, b = r.bottom + window.scrollY;
        if (top === null || t < top) { top = t; }
        if (bottom === null || b > bottom) { bottom = b; }
      }
      if (top === null) { return; }
      place('bar', top, Math.max(4, bottom - top), range.k === 'a' ? '#34c759' : '#0a84ff', 2, 3);
    });
    changeState.deletions.forEach(function (offset) {
      var y = null;
      var start = Math.max(0, stampLowerBound(bases, offset) - 1);
      for (var i = start; i < els.length; i++) {
        if (bases[i] + els[i].textContent.length >= offset) {
          y = els[i].getBoundingClientRect().top + window.scrollY;
          break;
        }
      }
      if (y === null) {
        var last = els[els.length - 1].getBoundingClientRect();
        y = last.bottom + window.scrollY;
      }
      place('tick', y - 1.5, 3, '#ff453a', 0, 8);
    });
  }
  // Marker redraws coalesce into one pass — several triggers can land
  // together (swap + line-change push + resize). setTimeout, not
  // requestAnimationFrame: rAF doesn't run in occluded windows, and markers
  // must still appear there (see __mdRestoreScrollThenCaret).
  var markerRedrawArmed = false;
  function scheduleChangeMarkerRedraw() {
    if (markerRedrawArmed) { return; }
    markerRedrawArmed = true;
    window.setTimeout(function () { markerRedrawArmed = false; drawChangeMarkers(); }, 16);
  }
  window.__mdSetLineChanges = function (state) {
    changeState = state;
    scheduleChangeMarkerRedraw();
    // Layout often settles after the first pass (fonts, images) — one
    // deferred redraw catches the common shifts.
    window.setTimeout(scheduleChangeMarkerRedraw, 300);
  };
  window.addEventListener('resize', scheduleChangeMarkerRedraw);
  report();
})();
