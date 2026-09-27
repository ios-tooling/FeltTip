//
//  MarkdownWebViewSchemeHandler.swift
//  FeltTip
//

import Foundation
import UniformTypeIdentifiers
import WebKit

/// Thread-safe filesystem boundary shared by the SwiftUI update path and the
/// URL-scheme handler. A web page may request only supported resources beneath
/// the document folder that supplied its base URL.
final class LocalResourceAccessPolicy: @unchecked Sendable {
	static let maximumResourceBytes = 64 * 1024 * 1024
	private let lock = NSLock()
	private var root: URL?

	func setRoot(_ url: URL?) {
		let resolved = url?.standardizedFileURL.resolvingSymlinksInPath()
		lock.lock()
		root = resolved
		lock.unlock()
	}

	func authorizedFileURL(for requestURL: URL) -> URL? {
		guard let candidate = authorizedCandidate(for: requestURL) else { return nil }
		guard let type = UTType(filenameExtension: candidate.pathExtension),
			  type.conforms(to: .image)
				|| type.conforms(to: .audiovisualContent)
				|| type.conforms(to: .font)
		else { return nil }
		guard let size = try? candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize,
			  size <= Self.maximumResourceBytes else { return nil }
		return candidate
	}

	func authorizedMarkdownURL(for requestURL: URL) -> URL? {
		guard let candidate = authorizedCandidate(for: requestURL),
		      MarkdownLinkExtensions.all.contains(candidate.pathExtension.lowercased())
		else { return nil }
		return candidate
	}

	private func authorizedCandidate(for requestURL: URL) -> URL? {
		let isResourceURL = requestURL.scheme == MarkdownWebView.resourceScheme
			&& requestURL.host == "res"
		guard isResourceURL || requestURL.isFileURL else { return nil }
		lock.lock()
		let root = root
		lock.unlock()
		guard let root else { return nil }
		let candidate = URL(fileURLWithPath: requestURL.path)
			.standardizedFileURL.resolvingSymlinksInPath()
		let rootPath = root.path
		guard candidate.path == rootPath
			|| candidate.path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
		else { return nil }
		return candidate
	}
}

/// Serves local files referenced by the rendered page (images, etc.) under the
/// custom resource scheme. The request URL's path is the real filesystem path,
/// so we read the bytes directly — the way to show local images in a
/// `loadHTMLString` page, which WKWebView won't let load `file://` subresources.
final class LocalResourceSchemeHandler: NSObject, WKURLSchemeHandler {
	weak var coordinator: MarkdownWebView.Coordinator?
	private let accessPolicy: LocalResourceAccessPolicy

	init(coordinator: MarkdownWebView.Coordinator?, accessPolicy: LocalResourceAccessPolicy) {
		self.coordinator = coordinator
		self.accessPolicy = accessPolicy
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
		guard let fileURL = accessPolicy.authorizedFileURL(for: url) else {
			task.didFailWithError(URLError(.noPermissionsToReadFile))
			let coordinator = coordinator
			Task { @MainActor in coordinator?.reportResourceAccessDenied() }
			return
		}
		guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
			task.didFailWithError(URLError(.noPermissionsToReadFile))
			let coordinator = coordinator
			Task { @MainActor in coordinator?.reportResourceAccessDenied() }
			return
		}
		defer { try? handle.close() }
		guard let data = try? handle.read(
				upToCount: LocalResourceAccessPolicy.maximumResourceBytes + 1),
			  data.count <= LocalResourceAccessPolicy.maximumResourceBytes else {
			task.didFailWithError(URLError(.dataLengthExceedsMaximum))
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
