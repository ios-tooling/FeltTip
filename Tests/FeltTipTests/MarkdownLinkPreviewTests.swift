import Foundation
import Testing
import WebKit
@testable import FeltTip

@Suite("Local Markdown link previews")
struct MarkdownLinkPreviewTests {
	@Test("Loads frontmatter from an authorized local Markdown link")
	func loadsFrontmatter() async throws {
		let folder = FileManager.default.temporaryDirectory
			.appending(path: "markdown-link-preview-\(UUID().uuidString)", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		let file = folder.appending(path: "linked note.md")
		try "---\ntitle: Linked note\ndescription: >-\n  A folded\n  description.\ntags: [swift, macOS]\n---\n\n# Body".write(to: file, atomically: true, encoding: .utf8)

		let policy = LocalResourceAccessPolicy()
		policy.setRoot(folder)
		let request = try #require(URL(string: "markerlocalres://res\(file.path(percentEncoded: true))"))
		let preview = await MarkdownLinkPreviewLoader.load(requestURL: request, accessPolicy: policy)

		#expect(preview?.filename == "linked note.md")
		#expect(preview?.pairs.map(\.key) == ["title", "description", "tags"])
		#expect(preview?.pairs.map(\.value) == ["Linked note", "A folded description.", "[swift, macOS]"])
	}

	@Test("Returns no preview when frontmatter is absent")
	func requiresFrontmatter() async throws {
		let folder = FileManager.default.temporaryDirectory
			.appending(path: "markdown-link-preview-\(UUID().uuidString)", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		let file = folder.appending(path: "plain.md")
		try "# No frontmatter".write(to: file, atomically: true, encoding: .utf8)

		let policy = LocalResourceAccessPolicy()
		policy.setRoot(folder)
		let request = try #require(URL(string: "markerlocalres://res\(file.path(percentEncoded: true))"))

		#expect(await MarkdownLinkPreviewLoader.load(requestURL: request, accessPolicy: policy) == nil)
	}

	@Test("Loads an absolute file URL within the authorized folder")
	func loadsFileURL() async throws {
		let folder = FileManager.default.temporaryDirectory
			.appending(path: "markdown-link-preview-\(UUID().uuidString)", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		let file = folder.appending(path: "absolute.markdown")
		try "---\ntitle: Absolute\n---".write(to: file, atomically: true, encoding: .utf8)
		let policy = LocalResourceAccessPolicy()
		policy.setRoot(folder)

		let preview = await MarkdownLinkPreviewLoader.load(requestURL: file, accessPolicy: policy)

		#expect(preview?.pairs.first?.value == "Absolute")
	}

	@Test("Rejects Markdown links outside the authorized document folder")
	func rejectsOutsideRoot() async throws {
		let root = FileManager.default.temporaryDirectory
			.appending(path: "markdown-link-preview-root-\(UUID().uuidString)", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: root) }
		let outside = FileManager.default.temporaryDirectory
			.appending(path: "outside-\(UUID().uuidString).md")
		try "---\ntitle: Private\n---".write(to: outside, atomically: true, encoding: .utf8)
		defer { try? FileManager.default.removeItem(at: outside) }

		let policy = LocalResourceAccessPolicy()
		policy.setRoot(root)
		let request = try #require(URL(string: "markerlocalres://res\(outside.path(percentEncoded: true))"))

		#expect(await MarkdownLinkPreviewLoader.load(requestURL: request, accessPolicy: policy) == nil)
	}

	@Test("A stalled authorized link read times out")
	func stalledReadTimesOut() async throws {
		let folder = FileManager.default.temporaryDirectory
			.appending(path: "markdown-link-preview-\(UUID().uuidString)", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		let file = folder.appending(path: "stalled.md")
		try Data().write(to: file)
		let policy = LocalResourceAccessPolicy()
		policy.setRoot(folder)
		let gate = DispatchSemaphore(value: 0)

		let preview = await MarkdownLinkPreviewLoader.load(
			requestURL: file,
			accessPolicy: policy,
			timeout: .milliseconds(20)) { _ in
				_ = gate.wait(timeout: .now() + 10)
				return MarkdownLinkPreview(filename: "unexpected.md", pairs: [])
			}
		gate.signal()

		#expect(preview == nil)
	}
}

@Suite(.serialized) @MainActor
struct MarkdownLinkPreviewIntegrationTests {
	@Test("Missing frontmatter serializes as JavaScript null")
	func missingFrontmatterResponse() {
		#expect(MarkdownWebView.Coordinator.linkPreviewJSON(nil) == "null")
	}

	@Test("Hovering a rendered local link displays its frontmatter card")
	func hoverDisplaysCard() async throws {
		let folder = FileManager.default.temporaryDirectory
			.appending(path: "markdown-link-preview-web-\(UUID().uuidString)", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		try "---\ntitle: Linked note\nauthor: Ben\n---\n\n# Body"
			.write(to: folder.appending(path: "linked.md"), atomically: true, encoding: .utf8)

		let view = MarkdownWebView(
			text: "Open [the linked note](linked.md)", theme: .default,
			fontSize: 14, baseURL: folder)
		let coordinator = MarkdownWebView.Coordinator(parent: view)
		let policy = LocalResourceAccessPolicy()
		policy.setRoot(folder)
		coordinator.localResourceAccessPolicy = policy
		let config = WKWebViewConfiguration()
		config.processPool = WKProcessPool()
		config.userContentController.add(WeakScriptMessageHandler(coordinator), name: "mdedit")
		config.userContentController.addUserScript(WKUserScript(
			source: MarkdownWebView.Coordinator.linkPreviewScript,
			injectionTime: .atDocumentEnd, forMainFrameOnly: true))
		config.setURLSchemeHandler(
			LocalResourceSchemeHandler(coordinator: coordinator, accessPolicy: policy),
			forURLScheme: MarkdownWebView.resourceScheme)
		let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 400), configuration: config)
		coordinator.webView = webView
		webView.navigationDelegate = coordinator
		coordinator.load(into: webView)

		try await waitUntil("preview script") {
			try await evaluate(webView, "typeof window.__mdShowLinkPreview") == "function"
		}
		_ = try await evaluate(webView, """
			(function () {
			  var link = document.querySelector('a[href]');
			  link.dispatchEvent(new PointerEvent('pointerover', { bubbles: true }));
			  return 'ok';
			})()
			""")
		try await waitUntil("frontmatter card") {
			try await evaluate(webView, "document.querySelector('.md-link-preview-title')?.textContent || ''") == "linked.md"
		}
		#expect(try await evaluate(webView, "document.querySelector('.md-link-preview dd')?.textContent || ''") == "Linked note")
	}

	private func evaluate(_ webView: WKWebView, _ script: String) async throws -> String? {
		try await BoundedTestCallbackWaiter.wait { completion in
			webView.evaluateJavaScript(script) { result, error in
				if let error { completion(.failure(error)) }
				else { completion(.success(result as? String)) }
			}
		}
	}

	private func waitUntil(_ label: String, condition: () async throws -> Bool) async throws {
		for _ in 0..<100 {
			if try await condition() { return }
			try await Task.sleep(for: .milliseconds(50))
		}
		Issue.record("Timed out waiting for \(label)")
	}
}
