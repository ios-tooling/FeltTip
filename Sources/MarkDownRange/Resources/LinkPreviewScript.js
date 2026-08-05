(function () {
  if (window.__mdLinkPreviewInstalled) { return; }
  window.__mdLinkPreviewInstalled = true;

  var markdownExtensions = new Set({{MARKDOWN_EXTENSIONS}});
  var activeLink = null;
  var activeRequest = 0;
  var hoverTimer = null;
  var savedTitle = null;
  var preview = document.createElement('aside');
  preview.id = 'md-link-preview';
  preview.className = 'md-link-preview';
  preview.setAttribute('role', 'tooltip');
  preview.hidden = true;
  document.body.appendChild(preview);

  var style = document.createElement('style');
  style.textContent = `
    .md-link-preview {
      position: fixed;
      z-index: 2147483647;
      box-sizing: border-box;
      width: min(360px, calc(100vw - 24px));
      padding: 12px 14px;
      border: 1px solid color-mix(in srgb, currentColor 22%, transparent);
      border-radius: 10px;
      background: Canvas;
      color: CanvasText;
      box-shadow: 0 8px 24px rgba(0, 0, 0, 0.22);
      font: 12px/1.4 -apple-system, BlinkMacSystemFont, sans-serif;
      text-align: left;
      pointer-events: none;
      -webkit-user-select: none;
      user-select: none;
    }
    .md-link-preview[hidden] { display: none; }
    .md-link-preview-title {
      margin: 0 0 8px;
      overflow: hidden;
      font-size: 12px;
      font-weight: 650;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .md-link-preview dl {
      display: grid;
      grid-template-columns: minmax(64px, max-content) minmax(0, 1fr);
      gap: 5px 12px;
      margin: 0;
    }
    .md-link-preview dt {
      color: color-mix(in srgb, CanvasText 62%, transparent);
      font-weight: 550;
    }
    .md-link-preview dd {
      display: -webkit-box;
      min-width: 0;
      margin: 0;
      overflow: hidden;
      overflow-wrap: anywhere;
      -webkit-box-orient: vertical;
      -webkit-line-clamp: 3;
    }
    .md-link-preview-more {
      margin: 8px 0 0;
      color: color-mix(in srgb, CanvasText 55%, transparent);
      font-size: 11px;
    }
  `;
  document.head.appendChild(style);

  function localMarkdownHref(link) {
    try {
      var url = new URL(link.href);
      if (url.protocol !== 'markerlocalres:' && url.protocol !== 'file:') { return null; }
      var name = decodeURIComponent(url.pathname).toLowerCase();
      var dot = name.lastIndexOf('.');
      if (dot < 0 || !markdownExtensions.has(name.slice(dot + 1))) { return null; }
      return url.href;
    } catch (_) {
      return null;
    }
  }

  function hide() {
    clearTimeout(hoverTimer);
    hoverTimer = null;
    preview.hidden = true;
    preview.replaceChildren();
    if (activeLink) {
      activeLink.removeAttribute('aria-describedby');
      if (savedTitle !== null) { activeLink.setAttribute('title', savedTitle); }
    }
    savedTitle = null;
    activeLink = null;
    activeRequest += 1;
  }

  function request(link, delay) {
    var href = localMarkdownHref(link);
    if (!href) { return; }
    if (activeLink !== link) { hide(); }
    activeLink = link;
    if (link.hasAttribute('title')) {
      savedTitle = link.getAttribute('title');
      link.removeAttribute('title');
    }
    var requestID = ++activeRequest;
    hoverTimer = setTimeout(function () {
      if (activeLink !== link || activeRequest !== requestID) { return; }
      window.webkit.messageHandlers.mdedit.postMessage({
        type: 'previewLink', href: href, requestID: requestID
      });
    }, delay);
  }

  window.__mdShowLinkPreview = function (requestID, model) {
    if (!activeLink || activeRequest !== requestID || !model || !model.pairs.length) { return; }
    preview.replaceChildren();
    var title = document.createElement('p');
    title.className = 'md-link-preview-title';
    title.textContent = model.filename;
    preview.appendChild(title);
    var list = document.createElement('dl');
    model.pairs.slice(0, 8).forEach(function (pair) {
      var key = document.createElement('dt');
      key.textContent = pair.key;
      var value = document.createElement('dd');
      value.textContent = pair.value || '—';
      list.append(key, value);
    });
    preview.appendChild(list);
    if (model.pairs.length > 8) {
      var more = document.createElement('p');
      more.className = 'md-link-preview-more';
      more.textContent = '+' + (model.pairs.length - 8) + ' more properties';
      preview.appendChild(more);
    }
    preview.hidden = false;
    activeLink.setAttribute('aria-describedby', preview.id);

    var anchor = activeLink.getBoundingClientRect();
    var box = preview.getBoundingClientRect();
    var left = Math.min(Math.max(12, anchor.left), window.innerWidth - box.width - 12);
    var top = anchor.bottom + 8;
    if (top + box.height > window.innerHeight - 12) {
      top = Math.max(12, anchor.top - box.height - 8);
    }
    preview.style.left = left + 'px';
    preview.style.top = top + 'px';
  };

  document.addEventListener('pointerover', function (event) {
    var link = event.target.closest && event.target.closest('a[href]');
    if (link && (!event.relatedTarget || !link.contains(event.relatedTarget))) { request(link, 350); }
  });
  document.addEventListener('pointerout', function (event) {
    if (activeLink && !activeLink.contains(event.relatedTarget)) { hide(); }
  });
  document.addEventListener('focusin', function (event) {
    var link = event.target.closest && event.target.closest('a[href]');
    if (link) { request(link, 0); }
  });
  document.addEventListener('focusout', function (event) {
    if (activeLink && !activeLink.contains(event.relatedTarget)) { hide(); }
  });
  window.addEventListener('scroll', hide, { passive: true });
})();
