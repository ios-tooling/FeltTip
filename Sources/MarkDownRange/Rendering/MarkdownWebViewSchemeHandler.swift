//
//  MarkdownWebViewSchemeHandler.swift
//  MarkDownRange
//

#if os(macOS)
import AppKit
import UniformTypeIdentifiers
import WebKit

/// Serves local files referenced by the rendered page (images, etc.) under the
/// custom resource scheme. The request URL's path is the real filesystem path,
/// so we read the bytes directly — the way to show local images in a
/// `loadHTMLString` page, which WKWebView won't let load `file://` subresources.
final class LocalResourceSchemeHandler: NSObject, WKURLSchemeHandler {
	weak var coordinator: MarkdownWebView.Coordinator?

	init(coordinator: MarkdownWebView.Coordinator?) {
		self.coordinator = coordinator
		super.init()
	}

	/// The bundled mermaid engine, served once per process instead of being
	/// inlined (~3 MB) into every rendered HTML string. See `mermaidEmbed`.
	private static let mermaidEngineData: Data? = MermaidResources.engineJS.map { Data($0.utf8) }

	func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
		guard let url = task.request.url else {
			task.didFailWithError(URLError(.badURL)); return
		}
		if url.host == "mermaid" {
			guard let data = Self.mermaidEngineData else {
				task.didFailWithError(URLError(.fileDoesNotExist)); return
			}
			let response = URLResponse(url: url, mimeType: "text/javascript", expectedContentLength: data.count, textEncodingName: "utf-8")
			task.didReceive(response)
			task.didReceive(data)
			task.didFinish()
			return
		}
		let fileURL = URL(fileURLWithPath: url.path)
		guard let data = try? Data(contentsOf: fileURL) else {
			task.didFailWithError(URLError(.noPermissionsToReadFile))
			let coordinator = coordinator
			Task { @MainActor in coordinator?.reportResourceAccessDenied() }
			return
		}
		let mimeType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
		let response = URLResponse(url: url, mimeType: mimeType, expectedContentLength: data.count, textEncodingName: nil)
		task.didReceive(response)
		task.didReceive(data)
		task.didFinish()
	}

	func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

/// Breaks the WKUserContentController → handler retain cycle (the controller
/// holds the handler strongly, and the web view holds the controller).
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
	weak var delegate: WKScriptMessageHandler?
	init(_ delegate: WKScriptMessageHandler) { self.delegate = delegate }
	func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
		delegate?.userContentController(controller, didReceive: message)
	}
}
#endif
