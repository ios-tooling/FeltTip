//
//  MarkdownFootnote+Rendering.swift
//  MarkdownRendering
//

extension MarkdownFootnote {

	/// Returns text with footnote markers replaced by numbered superscript links
	/// (`[¹](footnote://id)`) that the formatted view can intercept via openURL.
	public static func renderableContent(from text: String, footnotes: [MarkdownFootnote]) -> String {
		guard !footnotes.isEmpty else { return text }

		let indexByID = Dictionary(uniqueKeysWithValues: footnotes.map { ($0.id, $0.displayIndex) })
		let inlineFootnotes = footnotes.filter { $0.id.hasPrefix("inline-") }
		var inlineIndex = 0
		var inCodeBlock = false
		var lines: [String] = []

		for line in text.components(separatedBy: .newlines) {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.hasPrefix("```") { inCodeBlock.toggle() }
			if inCodeBlock { lines.append(line); continue }
			if trimmed.firstMatch(of: /^\[\^[^\]]+\]:\s+/) != nil { continue }

			var result = ""
			var remaining = line[line.startIndex...]

			while let match = remaining.firstMatch(of: /\[\^([^\]]+)\]|\^\[([^\]]+)\]/) {
				result += remaining[..<match.range.lowerBound]

				if let label = match.output.1.map(String.init) {
					if let n = indexByID[label] {
						result += "[\(superscript(for: n))](footnote://\(label))"
					}
				} else if match.output.2 != nil, inlineIndex < inlineFootnotes.count {
					let fn = inlineFootnotes[inlineIndex]
					result += "[\(superscript(for: fn.displayIndex))](footnote://\(fn.id))"
					inlineIndex += 1
				}

				remaining = remaining[match.range.upperBound...]
			}
			result += remaining
			lines.append(result)
		}
		return lines.joined(separator: "\n")
	}

	public static func superscript(for n: Int) -> String {
		String(n).compactMap { superDigits[$0] }.map(String.init).joined()
	}

	private static let superDigits: [Character: Character] = [
		"0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
		"5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
	]
}
