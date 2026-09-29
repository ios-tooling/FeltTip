(function () {
  if (window.__mdFocusModeInstalled) return;
  window.__mdFocusModeInstalled = true;

  var enabled = false;
  var hasEditorFocus = false;
  var style = document.createElement('style');
  style.textContent = [
    'body.md-focus-mode > :not(.md-focus-active) { opacity: 0.3; }',
    'body.md-focus-mode > * { transition: opacity 120ms ease-out; }'
  ].join('\n');
  document.head.appendChild(style);

  function clearActive() {
    document.querySelectorAll('body > .md-focus-active').forEach(function (node) {
      node.classList.remove('md-focus-active');
    });
  }

  function topLevelBlock(node) {
    if (!node) return null;
    if (node.nodeType === Node.TEXT_NODE) node = node.parentElement;
    while (node && node.parentElement && node.parentElement !== document.body) {
      node = node.parentElement;
    }
    return node && node.parentElement === document.body ? node : null;
  }

  function refresh() {
    clearActive();
    var selection = window.getSelection();
    var block = topLevelBlock(selection && selection.rangeCount ? selection.anchorNode : document.activeElement);
    var active = enabled && hasEditorFocus && !!block;
    document.body.classList.toggle('md-focus-mode', active);
    if (active) block.classList.add('md-focus-active');
  }

  window.__mdSetFocusMode = function (flag) {
    enabled = !!flag;
    refresh();
  };
  document.addEventListener('selectionchange', refresh);
  document.addEventListener('focusin', function () {
    hasEditorFocus = true;
    refresh();
  });
  document.addEventListener('focusout', function () {
    hasEditorFocus = false;
    setTimeout(refresh, 0);
  });
  window.addEventListener('blur', function () {
    hasEditorFocus = false;
    refresh();
  });
  document.addEventListener('pointerdown', function () { requestAnimationFrame(refresh); });
  new MutationObserver(function () { requestAnimationFrame(refresh); })
    .observe(document.body, { childList: true });
})();
