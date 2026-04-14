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
			if parseDefinition(trimmed) != nil { continue }

			guard line.contains("[") else { lines.append(line); continue }

			var result = ""
			var i = line.startIndex
			while i < line.endIndex {
				let ch = line[i]
				if ch == "[", line.index(after: i) < line.endIndex, line[line.index(after: i)] == "^" {
					let labelStart = line.index(i, offsetBy: 2)
					if let closeIdx = line[labelStart...].firstIndex(of: "]") {
						let afterClose = line.index(after: closeIdx)
						if afterClose >= line.endIndex || line[afterClose] != ":" {
							let label = String(line[labelStart..<closeIdx])
							if let n = indexByID[label] {
								result += "[\(superscript(for: n))](footnote://\(label))"
							}
							i = afterClose; continue
						}
					}
				} else if ch == "^", line.index(after: i) < line.endIndex, line[line.index(after: i)] == "[" {
					let contentStart = line.index(i, offsetBy: 2)
					if let closeIdx = line[contentStart...].firstIndex(of: "]") {
						if inlineIndex < inlineFootnotes.count {
							let fn = inlineFootnotes[inlineIndex]
							result += "[\(superscript(for: fn.displayIndex))](footnote://\(fn.id))"
							inlineIndex += 1
						}
						i = line.index(after: closeIdx); continue
					}
				}
				result.append(ch)
				i = line.index(after: i)
			}
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
