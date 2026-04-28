//
//  SwiftUIAttachment.swift
//  MarkDownRange
//
//  Phase 4: hosts an arbitrary SwiftUI view inline inside an NSTextView via
//  TextKit 2's NSTextAttachmentViewProvider hook. Used by the builder for
//  non-text blocks (code blocks, tables, images, etc.) and by the renderer
//  to prepend optional headers (e.g. the gallery preview's header card).
//

#if os(macOS)
@preconcurrency import AppKit
import SwiftUI

/// NSTextAttachment that builds its hosted view lazily. The builder closure
/// is @MainActor because SwiftUI views must be constructed on the main
/// thread; TextKit invokes loadView on the main thread, so this is safe.
@MainActor
public final class SwiftUIAttachment: NSTextAttachment {
	public let viewBuilder: () -> AnyView

	/// The width used for upfront measurement. The actual rendered width may
	/// differ slightly; small differences cause text-wrap height variance but
	/// are usually within tolerance for our use cases.
	private static let measurementWidth: CGFloat = 700

	/// A single NSHostingView reused across viewport entries/exits. TextKit
	/// destroys and recreates view providers when attachments leave/re-enter
	/// the viewport, so re-creating the host each time causes a render flash.
	/// Caching here keeps the rendered content alive across re-creations.
	fileprivate var cachedHost: NSHostingView<AnyView>?

	public init(_ viewBuilder: @escaping () -> AnyView) {
		self.viewBuilder = viewBuilder
		super.init(data: nil, ofType: nil)
		// Measure the view via NSHostingController to get our static bounds,
		// then assign a transparent NSImage of that size as the placeholder.
		// We deliberately do NOT pre-render the SwiftUI view to a bitmap:
		// blocks with async content (CachedURLImage / AsyncImage) snapshot
		// in their loading state, producing a wrong-looking placeholder
		// that briefly shows under the live host once it loads. Without a
		// non-nil image, AppKit draws the prohibitory "broken attachment"
		// glyph instead, which is also wrong. A transparent image at the
		// correct size avoids both — the gap before loadView is just empty
		// space, and the cached host eliminates re-entry flashes.
		let measureWidth = Self.measurementWidth
		let controller = NSHostingController(
			rootView: viewBuilder()
				.frame(maxWidth: measureWidth, alignment: .leading)
				.fixedSize(horizontal: false, vertical: true)
		)
		let fitting = controller.sizeThatFits(in: CGSize(width: measureWidth, height: CGFloat.greatestFiniteMagnitude))
		let size = CGSize(width: measureWidth, height: max(fitting.height, 24))
		self.bounds = CGRect(origin: .zero, size: size)
		self.image = Self.transparentImage(size: size)
	}

	public required init?(coder: NSCoder) { nil }

	private static func transparentImage(size: CGSize) -> NSImage {
		let image = NSImage(size: size)
		image.lockFocus()
		NSColor.clear.setFill()
		NSRect(origin: .zero, size: size).fill()
		image.unlockFocus()
		return image
	}

	public override func viewProvider(for parentView: NSView?, location: any NSTextLocation, textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
		let provider = SwiftUIAttachmentViewProvider(
			textAttachment: self,
			parentView: parentView,
			textLayoutManager: textContainer?.textLayoutManager,
			location: location
		)
		// We supply our own attachmentBounds via the provider, so TextKit
		// always has a non-zero size during initial layout. Tracking the
		// view's bounds dynamically caused a brief broken-attachment glyph
		// to appear before loadView ran (the view is nil at that moment).
		provider.tracksTextAttachmentViewBounds = false
		return provider
	}
}

@MainActor
private final class SwiftUIAttachmentViewProvider: NSTextAttachmentViewProvider {
	override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation, textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
		// Use the attachment's pre-measured bounds so TextKit always has a
		// concrete size to lay out, even before loadView runs. Without this,
		// TextKit can fall back to drawing the broken-attachment glyph.
		if let attachment = textAttachment as? SwiftUIAttachment {
			return attachment.bounds
		}
		return .zero
	}

	override func loadView() {
		guard let attachment = textAttachment as? SwiftUIAttachment else {
			view = NSView()
			return
		}
		// Inline the cache check + creation to avoid Swift 6 cross-isolation
		// "sending self/attachment" errors that arise when extracted into a
		// helper method. TextKit re-creates view providers when an attachment
		// re-enters the viewport; reusing the same NSHostingView eliminates
		// the re-render flash.
		if let cached = attachment.cachedHost {
			cached.removeFromSuperview()
			view = cached
			return
		}
		let wrapped = AnyView(
			attachment.viewBuilder()
				.frame(maxWidth: .infinity, alignment: .leading)
				.fixedSize(horizontal: false, vertical: true)
		)
		let h = NSHostingView(rootView: wrapped)
		h.translatesAutoresizingMaskIntoConstraints = false
		h.sizingOptions = [.intrinsicContentSize]
		attachment.cachedHost = h
		view = h
	}
}
#endif
