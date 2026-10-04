//
//  MarkdownPDFRenderer.swift
//  FeltTip
//

import CoreGraphics
import Foundation
import WebKit
#if os(macOS)
	import AppKit
#else
	import UIKit
#endif

/// Renders a markdown HTML document into a paginated, letter-sized PDF entirely
/// off-screen — no visible window required.
///
/// `WKWebView.printOperation(with:)` crashes in `_validatePagination` on modern
/// macOS, so each page is captured at 1:1 via `WKPDFConfiguration.rect` and the
/// slices are stitched together with a `CGContext` PDF. (A single `createPDF`
/// page is clamped to ~14400pt, which silently truncates long documents.) Page
/// breaks are nudged so an unbreakable element is never split across a boundary.
@MainActor
public enum MarkdownPDFRenderer {
	public static let pageWidth: CGFloat = 612    // US Letter, points
	public static let pageHeight: CGFloat = 792

	/// Render a full HTML document (as produced by
	/// `MarkdownHTMLRenderer.renderDocument`) into PDF data. Returns nil if the
	/// web content fails to load or no graphics context can be created.
	public static func pdfData(
		html: String,
		fontSize: CGFloat = 13,
		margin: CGFloat = 36,
		allowRemoteResources: Bool = false
	) async -> Data? {
		let printW = pageWidth - 2 * margin
		let printH = pageHeight - 2 * margin
		guard fontSize.isFinite, fontSize > 0,
			margin.isFinite, margin >= 0,
			printW > 0, printH > 0 else { return nil }
		let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: printW, height: pageHeight))
		let loader = WebViewLoadWaiter()
		webView.navigationDelegate = loader
		let securedHTML = securingForWebView(
			html, allowRemoteResources: allowRemoteResources)
		webView.loadHTMLString(
			injectingPrintCSS(into: securedHTML, fontSize: fontSize),
			baseURL: nil)
		do { try await loader.wait() } catch { return nil }
		// WebKit's system-font PDF maps alias Greek mu to the micro sign and emit
		// Arabic presentation forms. Route only those runs through a face whose
		// character map preserves source Unicode, and isolate right-to-left runs so
		// a page wrap cannot split a searchable phrase. Other text keeps its font.
		_ = try? await evaluateJavaScript(#"""
		(() => {
		  const greek = '[\\u0370-\\u03ff\\u1f00-\\u1fff]';
		  const arabic = '[\\u0600-\\u06ff\\u0750-\\u077f\\u08a0-\\u08ff\\ufb50-\\ufdff\\ufe70-\\ufeff]';
		  const hebrew = '[\\u0590-\\u05ff\\ufb1d-\\ufb4f]';
		  const affectedRuns = new RegExp(
		    greek + '(?:' + greek + '|\\p{M}|[ \\t](?=' + greek + '))*|' +
		    arabic + '(?:' + arabic + '|\\p{M}|[ \\t](?=' + arabic + '))*|' +
		    hebrew + '(?:' + hebrew + '|\\p{M}|[ \\t](?=' + hebrew + '))*', 'gu');
		  const needsSafeFont = new RegExp(greek + '|' + arabic, 'u');
		  const isRightToLeft = new RegExp(arabic + '|' + hebrew, 'u');
		  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
		  const nodes = [];
		  while (walker.nextNode()) {
		    const node = walker.currentNode;
		    const parent = node.parentElement;
		    if (parent && !parent.closest('script, style')) nodes.push(node);
		  }
		  for (const node of nodes) {
		    const text = node.nodeValue || '';
		    const matches = Array.from(text.matchAll(affectedRuns));
		    if (!matches.length) continue;
		    const fragment = document.createDocumentFragment();
		    let cursor = 0;
		    for (const match of matches) {
		      if (match.index > cursor) fragment.append(text.slice(cursor, match.index));
		      const span = document.createElement('span');
		      if (needsSafeFont.test(match[0])) {
		        span.style.fontFamily = 'Tahoma, "Noto Sans", "Geeza Pro", sans-serif';
		      }
		      if (isRightToLeft.test(match[0])) {
		        span.dir = 'rtl';
		        span.style.unicodeBidi = 'isolate';
		        span.style.whiteSpace = 'nowrap';
		      }
		      span.textContent = match[0];
		      fragment.append(span);
		      cursor = match.index + match[0].length;
		    }
		    if (cursor < text.length) fragment.append(text.slice(cursor));
		    node.replaceWith(fragment);
		  }
		})()
		"""#, in: webView)

		// Measure from the document origin through the body's content. The
		// documentElement's scrollHeight is at least the initial viewport height
		// (creating a blank page for short documents), while body.scrollHeight
		// omits the body's top offset from a collapsed first-child margin (which
		// can clip the last content). Keep a point of rounding slack at the end.
		var cssHeight = pageHeight
		if let raw = try? await evaluateJavaScript("""
			(() => {
			  const body = document.body;
			  const rect = body.getBoundingClientRect();
			  return Math.ceil(Math.max(rect.bottom, rect.top + body.scrollHeight) + window.scrollY) + 1;
			})()
			""", in: webView),
		   let h = (raw as? Double).map({ CGFloat($0) }), h > 0 {
			cssHeight = h
			webView.frame = CGRect(origin: webView.frame.origin,
			                       size: CGSize(width: printW, height: h))
			// Force a re-layout at the new size before snapshotting.
			_ = try? await evaluateJavaScript(
				"window.getComputedStyle(document.body).height", in: webView)
		}

		let boxes = await unbreakableBoxes(in: webView)
		let headings = await headingBoxes(in: webView)
		let links = await linkRegions(in: webView)
		let result = await paginate(
			webView: webView,
			contentHeight: cssHeight,
			margin: margin,
			unbreakable: boxes,
			headings: headings,
			links: links)
		_ = loader
		return result
	}

	/// Print-only overrides injected ahead of the renderer's own styles. A later
	/// `<style>` wins on equal specificity, so this tunes the printed output
	/// without touching the shared exporter CSS.
	static func injectingPrintCSS(into html: String, fontSize: CGFloat) -> String {
		let css = """
		<style>
		body { font-size: \(Int(fontSize))px; padding: 0; }
		table { table-layout: fixed; width: 100%; }
		th, td { overflow-wrap: anywhere; word-break: break-word; }
		pre { white-space: pre-wrap; overflow-wrap: anywhere; }
		code { overflow-wrap: anywhere; word-break: break-word; }
		</style>
		"""
		return html.replacingOccurrences(of: "</head>", with: css + "</head>")
	}

	/// An export is another untrusted WebView render surface. Keep remote images
	/// and media from becoming tracking requests (or delaying a PDF indefinitely)
	/// unless the caller deliberately opts in.
	static func securingForWebView(_ html: String, allowRemoteResources: Bool) -> String {
		let policy = MarkdownHTMLRenderer.webViewContentSecurityPolicy(
			allowRemoteResources: allowRemoteResources)
		let meta = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">"
		guard let head = html.range(of: "<head>", options: .caseInsensitive) else {
			return meta + html
		}
		var secured = html
		secured.insert(contentsOf: meta, at: head.upperBound)
		return secured
	}

	/// Document-relative top + height (CSS px) of elements we don't want split
	/// across a page boundary. Fed to the slicer so it can nudge page breaks.
	static func unbreakableBoxes(in webView: WKWebView) async -> [(top: CGFloat, height: CGFloat)] {
		await boxes(in: webView, selector: "pre, table, img, blockquote, p, div, tr, h1, h2, h3, h4, h5, h6, li")
	}

	/// Headings only — used to avoid leaving a heading widowed at a page bottom.
	static func headingBoxes(in webView: WKWebView) async -> [(top: CGFloat, height: CGFloat)] {
		await boxes(in: webView, selector: "h1, h2, h3, h4, h5, h6")
	}

	struct PDFLinkRegion {
		let url: URL
		let left: CGFloat
		let top: CGFloat
		let width: CGFloat
		let height: CGFloat
	}

	/// WebKit's sliced PDFs lose their annotations when their drawing is copied
	/// into the final paginated context. Capture link geometry from the laid-out
	/// page so pagination can restore clickable URL annotations on each slice.
	static func linkRegions(in webView: WKWebView) async -> [PDFLinkRegion] {
		let script = #"""
		JSON.stringify(Array.from(document.querySelectorAll('a[href]')).flatMap(function(a) {
		  var href = a.getAttribute('href');
		  if (!href) return [];
		  return Array.from(a.getClientRects()).map(function(r) {
		    return { href: href, left: r.left + window.scrollX,
		             top: r.top + window.scrollY, width: r.width, height: r.height };
		  });
		}))
		"""#
		guard let result = try? await evaluateJavaScript(script, in: webView),
		      let raw = result as? String,
		      let data = raw.data(using: .utf8),
		      let decoded = try? JSONDecoder().decode([PDFLinkPayload].self, from: data)
		else { return [] }
		return decoded.compactMap { payload in
			guard let url = URL(string: payload.href),
			      payload.width > 0, payload.height > 0 else { return nil }
			return PDFLinkRegion(
				url: url, left: payload.left, top: payload.top,
				width: payload.width, height: payload.height)
		}
	}

	private struct PDFLinkPayload: Decodable {
		let href: String
		let left: CGFloat
		let top: CGFloat
		let width: CGFloat
		let height: CGFloat
	}

	private static func boxes(in webView: WKWebView, selector: String) async -> [(top: CGFloat, height: CGFloat)] {
		let js = """
		JSON.stringify(Array.from(document.querySelectorAll('\(selector)'))
			.map(function(e){ var r = e.getBoundingClientRect(); return [r.top + window.scrollY, r.height]; }))
		"""
		guard let result = try? await evaluateJavaScript(js, in: webView),
			  let raw = result as? String else { return [] }
		return await decodeBoxesJSON(raw)
	}

	/// Decode document-sized geometry away from the UI actor. A long report can
	/// return tens of thousands of boxes and several megabytes of JSON; doing
	/// both JSONDecoder work and tuple conversion on MainActor visibly stalled
	/// the export UI before pagination even began.
	nonisolated static func decodeBoxesJSON(
		_ raw: String
	) async -> [(top: CGFloat, height: CGFloat)] {
		guard !Task.isCancelled else { return [] }
		let worker = Task.detached(priority: .userInitiated) {
			() -> [(top: CGFloat, height: CGFloat)] in
			guard !Task.isCancelled,
				  let data = raw.data(using: .utf8),
				  let decoded = try? JSONDecoder().decode(
					[[Double]].self, from: data) else { return [] }
			var boxes: [(top: CGFloat, height: CGFloat)] = []
			boxes.reserveCapacity(decoded.count)
			for (index, pair) in decoded.enumerated() {
				if index & 1_023 == 0, Task.isCancelled { return [] }
				guard pair.count == 2 else { continue }
				boxes.append((CGFloat(pair[0]), CGFloat(pair[1])))
			}
			return boxes
		}
		let boxes = await withTaskCancellationHandler(
			operation: { await worker.value },
			onCancel: { worker.cancel() })
		return Task.isCancelled ? [] : boxes
	}
}
