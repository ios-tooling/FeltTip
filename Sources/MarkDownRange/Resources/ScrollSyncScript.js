(function () {
  if (window.__mdScrollSyncInstalled) { return; }
  window.__mdScrollSyncInstalled = true;
  function docHeight() {
    return Math.max(document.documentElement.scrollHeight, document.body.scrollHeight, 1);
  }
  // While a host-driven scroll is in flight, its echo must not report as
  // a user scroll — in a split view that echo claims scroll-sourcehood
  // and yanks the pane the user is actually scrolling. The echo is
  // consumed when the position settles at the target (or after a grace
  // period, if the user interrupted the drive).
  var driven = null;
  function report() {
    var h = docHeight();
    var vis = window.innerHeight;
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
    var maxY = Math.max(h - vis, 0);
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
    var h = docHeight();
    var vis = window.innerHeight;
    var maxY = Math.max(h - vis, 0);
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
  window.__mdRestoreScrollThenCaret = function (y, caret, length) {
    var deadline = Date.now() + 1000;
    function attempt() {
      var maxY = Math.max(document.documentElement.scrollHeight, document.body.scrollHeight) - window.innerHeight;
      if (maxY >= y || Date.now() > deadline) {
        var target = Math.min(y, Math.max(maxY, 0));
        driven = { y: target, until: Date.now() + 500 };
        window.scrollTo(0, target);
        if (caret != null && window.__mdPlaceCaret) { window.__mdPlaceCaret(caret, length || 0); }
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
  window.__mdSwapContent = function (html) {
    document.body.innerHTML = html;
    if (window.__mdAfterSwap) { window.__mdAfterSwap(); }
    drawChangeMarkers();
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
    var spans = document.querySelectorAll('[data-s]');
    if (!spans.length) { return; }
    function place(cls, top, height, color, left, width) {
      var bar = document.createElement('div');
      bar.className = 'mdr-change-marker';
      bar.style.cssText = 'position:absolute;pointer-events:none;z-index:9;border-radius:1.5px;'
        + 'left:' + left + 'px;width:' + width + 'px;top:' + top + 'px;height:' + height + 'px;background:' + color + ';';
      document.body.appendChild(bar);
    }
    changeState.ranges.forEach(function (range) {
      // Union the vertical extents of the runs overlapping [s, e).
      var top = null, bottom = null;
      for (var i = 0; i < spans.length; i++) {
        var base = parseInt(spans[i].getAttribute('data-s'), 10);
        if (base >= range.e) { break; }
        if (base + spans[i].textContent.length <= range.s) { continue; }
        var r = spans[i].getBoundingClientRect();
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
      for (var i = 0; i < spans.length; i++) {
        var base = parseInt(spans[i].getAttribute('data-s'), 10);
        if (base + spans[i].textContent.length >= offset) {
          y = spans[i].getBoundingClientRect().top + window.scrollY;
          break;
        }
      }
      if (y === null) {
        var last = spans[spans.length - 1].getBoundingClientRect();
        y = last.bottom + window.scrollY;
      }
      place('tick', y - 1.5, 3, '#ff453a', 0, 8);
    });
  }
  window.__mdSetLineChanges = function (state) {
    changeState = state;
    drawChangeMarkers();
    // Layout often settles after the first pass (fonts, images) — one
    // deferred redraw catches the common shifts.
    window.setTimeout(drawChangeMarkers, 300);
  };
  window.addEventListener('resize', function () {
    window.requestAnimationFrame(drawChangeMarkers);
  });
  report();
})();
