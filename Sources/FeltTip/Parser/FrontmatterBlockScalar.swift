//
//  FrontmatterBlockScalar.swift
//  FeltTip
//

import Foundation

/// The small YAML subset needed to display block-scalar frontmatter values.
/// This intentionally leaves mappings/sequences to their existing compact
/// representation while honoring folded/literal style and chomping indicators.
struct FrontmatterBlockScalar {
	private enum Style { case folded, literal }
	private enum Chomping { case clip, strip, keep }

	private let style: Style
	private let chomping: Chomping
	private let explicitIndent: Int?

	init?(indicator: String) {
		guard let first = indicator.first, first == ">" || first == "|" else { return nil }
		style = first == ">" ? .folded : .literal
		var chomping = Chomping.clip
		var explicitIndent: Int?
		for character in indicator.dropFirst() {
			switch character {
			case "-" where chomping == .clip: chomping = .strip
			case "+" where chomping == .clip: chomping = .keep
			case "1"..."9" where explicitIndent == nil:
				explicitIndent = character.wholeNumberValue
			default: return nil
			}
		}
		self.chomping = chomping
		self.explicitIndent = explicitIndent
	}

	func render(_ sourceLines: [String]) -> String {
		let indent = explicitIndent ?? sourceLines.lazy
			.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
			.map(Self.leadingWhitespaceCount)
			.min() ?? 0
		let lines = sourceLines.map { line -> String in
			guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
			return String(line.dropFirst(min(indent, line.count)))
		}

		var value: String
		switch style {
		case .literal:
			value = lines.joined(separator: "\n")
		case .folded:
			value = Self.fold(lines)
		}
		if !lines.isEmpty { value.append("\n") }
		return applyChomping(to: value)
	}

	private func applyChomping(to value: String) -> String {
		guard chomping != .keep else { return value }
		var stripped = value
		while stripped.last == "\n" { stripped.removeLast() }
		guard chomping == .clip, !stripped.isEmpty else { return stripped }
		return stripped + "\n"
	}

	private static func fold(_ lines: [String]) -> String {
		var result = ""
		var previousWasBlank = false
		for line in lines {
			if line.isEmpty {
				result.append("\n")
				previousWasBlank = true
			} else {
				if !result.isEmpty, !previousWasBlank { result.append(" ") }
				result.append(line)
				previousWasBlank = false
			}
		}
		return result
	}

	private static func leadingWhitespaceCount(_ line: String) -> Int {
		line.prefix { $0 == " " || $0 == "\t" }.count
	}
}
