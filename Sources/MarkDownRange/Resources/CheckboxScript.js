(function () {
  document.body.addEventListener('change', function (e) {
    var t = e.target;
    if (t && t.tagName === 'INPUT' && t.type === 'checkbox' && t.hasAttribute('data-cb')) {
      var idx = parseInt(t.getAttribute('data-cb'), 10);
      if (!isNaN(idx)) {
        var rev = window.__mdGetRev ? window.__mdGetRev() : null;
        window.webkit.messageHandlers.mdedit.postMessage({
          type: 'checkbox', index: idx, checked: t.checked, rev: rev
        });
      }
    }
  });
})();
