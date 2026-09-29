(function () {
  if (window.__mdImagePresentationInstalled) return;
  window.__mdImagePresentationInstalled = true;

  var enabled = false;
  var allowsRemoteResources = false;
  var activePinchImage = null;
  var pinchTriggered = false;
  var sizeObserver = new ResizeObserver(function (entries) {
    entries.forEach(function (entry) {
      enhance(entry.target);
      positionButton(entry.target);
    });
  });

  function isLarge(image) {
    var rect = image.getBoundingClientRect();
    return rect.width >= 320 || rect.height >= 240;
  }

  function canOpen(image) {
    if (!image) return false;
    try {
      var url = new URL(image.currentSrc || image.src || '', document.baseURI);
      if (url.protocol === 'http:' || url.protocol === 'https:') {
        return allowsRemoteResources;
      }
      return url.protocol === 'markerlocalres:' ||
        url.protocol === 'file:' || url.protocol === 'data:';
    } catch (_) {
      return false;
    }
  }

  function postOpen(image) {
    if (!enabled || !image || !isLarge(image) || !canOpen(image)) return;
    window.webkit.messageHandlers.mdedit.postMessage({
      type: 'openImage',
      source: image.currentSrc || image.src,
      alt: image.alt || ''
    });
  }

  function imageInside(element) {
    if (!element) return null;
    if (element.tagName === 'IMG') return element;
    var button = element.closest && element.closest('.md-image-open-button');
    return button ? button.__mdImageTarget : null;
  }

  function positionButton(image) {
    var button = image && image.__mdImageOpenButton;
    if (!button) return;
    if (!image.isConnected || !isLarge(image) || !canOpen(image)) {
      button.remove();
      delete image.__mdImageOpenButton;
      delete image.dataset.mdImageEnhanced;
      return;
    }
  }

  function enhance(image) {
    if (!enabled || !image || image.dataset.mdImageEnhanced === 'true' ||
        !isLarge(image) || !canOpen(image)) return;
    image.dataset.mdImageEnhanced = 'true';

    var button = document.createElement('button');
    button.type = 'button';
    button.tabIndex = 0;
    button.className = 'md-image-open-button';
    button.contentEditable = 'false';
    button.setAttribute('aria-label', 'Open image in zoomable window');
    button.title = 'Open image in zoomable window';
    button.__mdImageTarget = image;
    image.__mdImageOpenButton = button;
    button.innerHTML = '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M2.5 6V2.5H6M10 2.5h3.5V6M13.5 10v3.5H10M6 13.5H2.5V10"/></svg>';
    button.addEventListener('click', function (event) {
      event.preventDefault();
      event.stopPropagation();
      postOpen(image);
    });
    button.addEventListener('keydown', function (event) {
      if (event.key !== 'Enter' && event.key !== ' ') return;
      event.preventDefault();
      postOpen(image);
    });
    var target = image.parentElement && image.parentElement.tagName === 'A' ? image.parentElement : image;
    target.insertAdjacentElement('afterend', button);
  }

  function scan(root) {
    if (root && root.tagName === 'IMG') {
      sizeObserver.observe(root);
      if (root.complete) enhance(root);
      else root.addEventListener('load', function () { enhance(root); }, { once: true });
    }
    var images = (root || document).querySelectorAll ? (root || document).querySelectorAll('img') : [];
    images.forEach(function (image) {
      sizeObserver.observe(image);
      if (image.complete) enhance(image);
      else image.addEventListener('load', function () { enhance(image); }, { once: true });
    });
  }

  var style = document.createElement('style');
  style.textContent =
    '.md-image-open-button{position:relative;z-index:3;box-sizing:border-box;display:inline-flex;align-items:center;justify-content:center;' +
    'margin-left:-36px;vertical-align:bottom;transform:translate(-8px,-8px);' +
    'width:28px;height:28px;padding:5px;border:0;border-radius:7px;color:#222;background:#fff;box-shadow:0 1px 5px rgba(0,0,0,.35);cursor:zoom-in;opacity:.9;line-height:0;pointer-events:auto}' +
    '.md-image-open-button:hover,.md-image-open-button:focus-visible{opacity:1;outline:2px solid AccentColor;outline-offset:2px}' +
    '.md-image-open-button svg{width:18px;height:18px;fill:none;stroke:currentColor;stroke-width:1.6;stroke-linecap:round;stroke-linejoin:round}';
  document.head.appendChild(style);

  function removeEnhancements() {
    document.querySelectorAll('.md-image-open-button').forEach(function (button) {
      var image = button.__mdImageTarget;
      if (image) delete image.dataset.mdImageEnhanced;
      if (image) delete image.__mdImageOpenButton;
      button.remove();
    });
  }

  window.__mdSetImagePresentationEnabled = function (shouldEnable, shouldAllowRemoteResources) {
    enabled = !!shouldEnable;
    allowsRemoteResources = !!shouldAllowRemoteResources;
    removeEnhancements();
    if (!enabled) {
      return;
    }
    scan(document);
    requestAnimationFrame(function () { scan(document); });
  };

  new MutationObserver(function (records) {
    if (!enabled) return;
    records.forEach(function (record) {
      record.addedNodes.forEach(function (node) {
        if (node.nodeType === Node.ELEMENT_NODE) scan(node);
      });
    });
  }).observe(document.body, { childList: true, subtree: true });

  document.addEventListener('gesturestart', function (event) {
    activePinchImage = imageInside(document.elementFromPoint(event.clientX, event.clientY));
    pinchTriggered = false;
  }, { passive: false });

  document.addEventListener('gesturechange', function (event) {
    if (activePinchImage && !pinchTriggered && event.scale >= 1.2) {
      pinchTriggered = true;
      event.preventDefault();
      postOpen(activePinchImage);
    }
  }, { passive: false });

  document.addEventListener('gestureend', function () {
    activePinchImage = null;
    pinchTriggered = false;
  }, { passive: false });
})();
