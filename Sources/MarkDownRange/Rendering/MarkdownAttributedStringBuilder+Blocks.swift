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
		// Tables stretch to the available reading width and re-measure
		// whenever the text view resizes; everything else uses the static
		// measurement default.
		let measurementWidth: CGFloat?
		let usesContainerWidth: Bool
		switch block {
		case .table:
			measurementWidth = context.availableWidth
			usesContainerWidth = true
		default:
			measurementWidth = nil
			usesContainerWidth = false
		}
		let attachment = SwiftUIAttachment(width: measurementWidth, usesContainerWidth: usesContainerWidth) {
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
}
#endif
