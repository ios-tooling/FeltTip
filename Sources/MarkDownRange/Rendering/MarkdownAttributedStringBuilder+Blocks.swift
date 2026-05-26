//
//  MarkdownAttributedStringBuilder+Blocks.swift
//  MarkDownRange
//
//  Per-block rendering. Each helper appends to a shared NSMutableAttributedString
//  and emits its own paragraph terminator.
//

#if os(macOS)
import AppKit
import SwiftUI

extension MarkdownAttributedStringBuilder {
	static func appendHeading(level: Int, content: AttributedString, to out: NSMutableAttributedString, context: MarkdownRenderContext) {
		let font = headingNSFont(level: level, base: context.fontSize, family: context.theme.fontFamily)
		let color = NSColor(context.theme.headingColor)
		let para = NSMutableParagraphStyle()
		para.paragraphSpacingBefore = level <= 2 ? 24 : 16
		para.paragraphSpacing = level <= 2 ? 12 : 8
		if let alignment = context.paragraphAlignment { para.alignment = alignment }
		let inner = nsAttributedString(from: content, font: font, defaultColor: color, boldColor: NSColor(context.theme.textColor), fontFamily: context.theme.fontFamily)
		let start = out.length
		out.append(decorate(inner, paragraphStyle: para))
		let headingRange = NSRange(location: start, length: out.length - start)
		if headingRange.length > 0 {
			out.addAttribute(.markdownHeadingLevel, value: level, range: headingRange)
		}
		out.append(NSAttributedString(string: "\n"))
	}

	static func appendParagraph(content: AttributedString, to out: NSMutableAttributedString, context: MarkdownRenderContext) {
		let font = bodyNSFont(size: context.fontSize, family: context.theme.fontFamily)
		let color = NSColor(context.theme.textColor)
		let para = NSMutableParagraphStyle()
		para.paragraphSpacing = 10
		para.lineHeightMultiple = 1.4
		if let alignment = context.paragraphAlignment { para.alignment = alignment }
		let inner = nsAttributedString(from: content, font: font, defaultColor: color, fontFamily: context.theme.fontFamily)
		out.append(decorate(inner, paragraphStyle: para))
		out.append(NSAttributedString(string: "\n"))
	}

	/// Render a non-text block as an NSTextAttachment that hosts the block's
	/// existing SwiftUI view via NSHostingView. Each attachment occupies its
	/// own line so it visually behaves like a block.
	static func appendBlockAttachment(_ block: MarkdownBlock, to out: NSMutableAttributedString, context: MarkdownRenderContext) {
		let theme = context.theme
		let fontSize = context.fontSize
		let baseURL = context.baseURL
		// Tables and image-bearing blocks stretch to the available reading
		// width and re-measure whenever the text view resizes — without this,
		// wide cover images get sized to the static 700pt fallback and overflow
		// narrower windows. Everything else uses the static default.
		let measurementWidth: CGFloat?
		let usesContainerWidth: Bool
		switch block {
		case .table, .image, .imageRow, .figure:
			measurementWidth = context.availableWidth
			usesContainerWidth = true
		default:
			measurementWidth = nil
			usesContainerWidth = false
		}
		let attachment = SwiftUIAttachment(
			width: measurementWidth,
			usesContainerWidth: usesContainerWidth,
			contentKey: Self.contentKey(for: block, theme: theme, fontSize: fontSize)
		) {
			AnyView(
				MarkdownContentView.blockView(
					for: block,
					theme: theme,
					fontSize: fontSize,
					baseURL: baseURL,
					onLinkHover: nil
				)
			)
		}
		let para = NSMutableParagraphStyle()
		para.paragraphSpacingBefore = 14
		para.paragraphSpacing = 14
		if let alignment = context.paragraphAlignment { para.alignment = alignment }
		let attachmentString = NSMutableAttributedString(attachment: attachment)
		attachmentString.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: attachmentString.length))
		out.append(attachmentString)
		out.append(NSAttributedString(string: "\n"))
	}

	static func appendBlockquote(children: [MarkdownBlock], to out: NSMutableAttributedString, context: MarkdownRenderContext) {
		var inner = context
		inner.blockquoteDepth += 1
		let start = out.length
		for child in children { append(child, to: out, context: inner) }
		let range = NSRange(location: start, length: out.length - start)
		let para = NSMutableParagraphStyle()
		para.firstLineHeadIndent = CGFloat(inner.blockquoteDepth) * 16
		para.headIndent = CGFloat(inner.blockquoteDepth) * 16
		applyParagraphStyle(para, to: out, range: range)
		applyForegroundColor(NSColor(context.theme.secondaryColor), to: out, range: range)
		applyItalic(to: out, range: range)
		out.addAttribute(.markdownBlockquoteDepth, value: inner.blockquoteDepth, range: range)
	}

	static func appendThematicBreak(to out: NSMutableAttributedString, context: MarkdownRenderContext) {
		let para = NSMutableParagraphStyle()
		para.alignment = .center
		para.paragraphSpacingBefore = 16
		para.paragraphSpacing = 16
		let attrs: [NSAttributedString.Key: Any] = [
			.font: bodyNSFont(size: context.fontSize, family: context.theme.fontFamily),
			.foregroundColor: NSColor(context.theme.secondaryColor),
			.paragraphStyle: para,
		]
		out.append(NSAttributedString(string: "─────\n", attributes: attrs))
	}

	static func appendDefinitionList(items: [DefinitionItem], to out: NSMutableAttributedString, context: MarkdownRenderContext) {
		let bodyFont = bodyNSFont(size: context.fontSize, family: context.theme.fontFamily)
		let textColor = NSColor(context.theme.textColor)
		for item in items {
			out.append(NSAttributedString(string: item.term + "\n", attributes: [.font: bodyFont, .foregroundColor: textColor]))
			for def in item.definitions {
				let para = NSMutableParagraphStyle()
				para.firstLineHeadIndent = 16
				para.headIndent = 16
				out.append(NSAttributedString(string: def + "\n", attributes: [.font: bodyFont, .foregroundColor: textColor, .paragraphStyle: para]))
			}
		}
	}

	static func appendPlaceholder(_ text: String, to out: NSMutableAttributedString, context: MarkdownRenderContext) {
		let attrs: [NSAttributedString.Key: Any] = [
			.font: bodyNSFont(size: context.fontSize, family: context.theme.fontFamily),
			.foregroundColor: NSColor(context.theme.secondaryColor),
		]
		out.append(NSAttributedString(string: text + "\n", attributes: attrs))
	}

	/// Stable content fingerprint for a block, used by the renderer's
	/// in-place patch to tell whether a rebuilt attachment is the same as
	/// the one already mounted. Theme + font size are folded in because they
	/// change what the hosted view draws even when the block is unchanged.
	private static func contentKey(for block: MarkdownBlock, theme: MarkdownTheme, fontSize: CGFloat) -> String {
		"\(theme.signature)|\(fontSize)|\(blockFingerprint(block))"
	}

	private static func blockFingerprint(_ block: MarkdownBlock) -> String {
		switch block {
		case .image(let src, let alt, let w, let h, _):
			return "image|\(src)|\(alt)|\(w ?? -1)|\(h ?? -1)"
		case .imageRow(let images, _):
			let parts = images.map { "\($0.source)~\($0.alt)~\($0.width ?? -1)~\($0.height ?? -1)~\($0.link?.absoluteString ?? "")" }
			return "imageRow|" + parts.joined(separator: ";")
		case .figure(let img, let caption, _):
			return "figure|\(img.source)|\(img.alt)|\(img.width ?? -1)|\(img.height ?? -1)|\(caption)"
		case .codeBlock(let code, let lang, _):
			return "code|\(lang ?? "")|\(code)"
		case .htmlBlock(let html, _):
			return "html|\(html)"
		case .table(let header, let rows, let aligns, _):
			let h = header.map(cellFingerprint).joined(separator: "\t")
			let r = rows.map { $0.map(cellFingerprint).joined(separator: "\t") }.joined(separator: "\n")
			let a = aligns.map { String(describing: $0) }.joined(separator: ",")
			return "table|\(a)|\(h)|\(r)"
		case .details(let summary, let children, _):
			return "details|\(summary)|" + children.map(blockFingerprint).joined(separator: "#")
		case .alert(let type, let children, _):
			return "alert|\(type)|" + children.map(blockFingerprint).joined(separator: "#")
		case .frontmatter(let pairs, _):
			return "front|" + pairs.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
		default:
			return block.id
		}
	}

	private static func cellFingerprint(_ cell: TableCell) -> String {
		switch cell {
		case .text(let str): return String(str.characters)
		case .image(let src, let alt, let link, let w, let h):
			return "img:\(src)~\(alt)~\(link?.absoluteString ?? "")~\(w ?? -1)~\(h ?? -1)"
		}
	}
}
#endif
