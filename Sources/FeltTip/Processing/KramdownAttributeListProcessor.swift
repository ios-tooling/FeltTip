import Foundation

/// Recognizes Kramdown's standalone block attribute-list syntax. FeltTip does
/// not apply arbitrary CSS classes to native Markdown blocks, but displaying
/// the control line as prose is worse than ignoring unsupported presentation
/// metadata.
enum KramdownAttributeListProcessor {
	static func isStandaloneAttributeList(_ line: String) -> Bool {
		let trimmed = line.trimmingCharacters(in: .whitespaces)
		guard trimmed.hasPrefix("{:"), trimmed.hasSuffix("}") else { return false }
		let content = trimmed.dropFirst(2).dropLast()
		let tokens = content.split(whereSeparator: { $0.isWhitespace })
		guard !tokens.isEmpty else { return false }
		return tokens.allSatisfy { token in
			guard token.first == "." || token.first == "#" else { return false }
			let name = token.dropFirst()
			return !name.isEmpty && name.allSatisfy {
				$0.isLetter || $0.isNumber || $0 == "_" || $0 == "-"
			}
		}
	}
}
