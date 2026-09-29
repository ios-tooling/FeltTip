//
//  MarkdownWebViewScripts.swift
//  FeltTip
//
//  Loads the web view's injected JS from bundled resource files and fills in
//  the few host-computed values ({{PLACEHOLDER}} substitution). The scripts
//  stay plain .js on disk so they're diffable and editable as JavaScript.
//

#if os(macOS)
	import AppKit
#else
	import UIKit
#endif

extension MarkdownWebView.Coordinator {
	/// Installed for every rendered page. Local Markdown links ask the host for
	/// bounded frontmatter metadata and render it beside the hovered link.
	static let linkPreviewScript = MarkdownWebViewScripts.linkPreviewScript

	/// Injected when a checkbox-toggle callback is wired (QuickLook). Reports a
	/// task-list checkbox click — by its `data-cb` document-wide index — so the
	/// host can rewrite the source. Works whether or not the page is editable.
	static let checkboxScript = MarkdownWebViewScripts.load("CheckboxScript")

	/// Installed after every load (editable or not). Reports scroll position as
	/// top/visible/content fractions — matching MarkdownTextView's semantics so a
	/// host can sync the two — and exposes scroll-control hooks the coordinator
	/// calls. Idempotent so repeated injection is harmless.
	static let scrollSyncScript = MarkdownWebViewScripts.load("ScrollSyncScript")

	/// Installed dormant in every view; hosts opt in before it decorates images.
	static let imagePresentationScript = MarkdownWebViewScripts.load("ImagePresentationScript")

	static func imagePresentationSetupScript(
		enabled: Bool,
		allowsRemoteResources: Bool
	) -> String {
		"window.__mdSetImagePresentationEnabled && window.__mdSetImagePresentationEnabled(\(enabled), \(allowsRemoteResources));"
	}

	/// Installed in every rendered page. Dormant until the host enables focus
	/// mode, then dims all top-level blocks except the caret/selection's block.
	static let focusModeScript = MarkdownWebViewScripts.load("FocusModeScript")

	/// Injected after each editable load. Maps contentEditable edits to source
	/// splices via `data-s` offsets, vetoing anything it can't map.
	static var editorScript: String { MarkdownWebViewScripts.editorScript }
}

enum MarkdownWebViewScripts {
	/// SwiftPM currently flattens processed resources into the bundle root.
	/// Prefer that exact file over Bundle's recursive lookup: an incremental
	/// build can retain an obsolete `Resources/` subtree from an older package
	/// layout, and `url(forResource:)` is then free to return the stale script.
	static func directResourceURL(_ name: String, resourceRoot: URL?) -> URL? {
		guard let url = resourceRoot?
			.appendingPathComponent(name)
			.appendingPathExtension("js"),
		      FileManager.default.fileExists(atPath: url.path) else { return nil }
		return url
	}

	static func load(_ name: String) -> String {
		guard let url = directResourceURL(name, resourceRoot: Bundle.module.resourceURL)
				?? Bundle.module.url(forResource: name, withExtension: "js"),
		      let script = try? String(contentsOf: url, encoding: .utf8) else {
			assertionFailure("Missing bundled script \(name).js")
			return ""
		}
		return script
	}

	static let editorScript: String = load("EditorScript")
		.replacingOccurrences(of: "{{LINK_ICON_CSS}}", with: linkOpenButtonIconCSS)
		.replacingOccurrences(of: "{{LINK_ICON_DATA_URI}}", with: linkOpenButtonIconDataURI ?? "")
		.replacingOccurrences(of: "{{LINK_ICON_CLASS}}", with: linkOpenButtonHasIcon ? " has-symbol-icon" : "")

	static let linkPreviewScript: String = load("LinkPreviewScript")
		.replacingOccurrences(
			of: "{{MARKDOWN_EXTENSIONS}}",
			with: (try? String(data: JSONSerialization.data(
				withJSONObject: MarkdownLinkExtensions.all.sorted()), encoding: .utf8)) ?? "[]")

	private static var linkOpenButtonHasIcon: Bool {
		linkOpenButtonIconDataURI != nil
	}

	private static var linkOpenButtonIconCSS: String {
		""
	}

	private static let linkOpenButtonIconDataURI: String? = {
		#if os(macOS)
			guard let symbol = NSImage(systemSymbolName: "arrow.right.circle", accessibilityDescription: nil) else { return nil }
			let size = NSSize(width: 14, height: 14)
			let image = NSImage(size: size)
			image.lockFocus()
			NSColor.labelColor.set()
			symbol.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
			image.unlockFocus()
			guard let tiff = image.tiffRepresentation,
			      let rep = NSBitmapImageRep(data: tiff),
			      let png = rep.representation(using: .png, properties: [:]) else { return nil }
		#else
			let config = UIImage.SymbolConfiguration(pointSize: 14)
			guard let symbol = UIImage(systemName: "arrow.right.circle", withConfiguration: config),
			      let png = symbol.withTintColor(.label, renderingMode: .alwaysOriginal).pngData()
			else { return nil }
		#endif
		return "data:image/png;base64,\(png.base64EncodedString())"
	}()
}
