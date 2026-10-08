//
//  CustomContainerProcessor.swift
//  FeltTip
//

import Foundation

/// markdown-it style custom containers:
///
///     ::: warning
///     **Watch out** — this can bite.
///     :::
///
/// We don't have a first-class block for arbitrary container types, so we
/// reuse the existing alert visual by reinterpreting `warning`/`info`/`note`/
/// `tip`/`caution`/`danger`/`important` as their GFM-alert equivalent — the
/// alert pass picks them up via `[!TYPE]`. Unknown container names fall back
/// to `note`. Skips fenced code blocks so source listings keep `:::` intact.
public enum CustomContainerProcessor {
	public static func process(_ text: String) -> String {
		MarkdownCodeProtection.transform(text) { processUnprotected($0) } ?? text
	}

	private static func processUnprotected(_ text: String) -> String {
		guard DocumentScan.hasLine(startingWith: ":::", in: text) else { return text }
		var output: [String] = []
		var inFence = false
		var i = 0
		let lines = text.components(separatedBy: "\n")
		while i < lines.count {
			let line = lines[i]
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
				inFence.toggle()
				output.append(line); i += 1; continue
			}
			if !inFence, let name = openingContainer(trimmed) {
				var body: [String] = []
				i += 1
				while i < lines.count {
					let inner = lines[i].trimmingCharacters(in: .whitespaces)
					if inner == ":::" { i += 1; break }
					body.append(lines[i])
					i += 1
				}
				output.append(contentsOf: render(name: name, body: body))
				continue
			}
			output.append(line); i += 1
		}
		return output.joined(separator: "\n")
	}

	private static func openingContainer(_ line: String) -> String? {
		guard line.hasPrefix(":::"), line != ":::" else { return nil }
		let after = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
		guard !after.isEmpty else { return nil }
		return String(after.split(separator: " ").first ?? "")
	}

	private static func render(name: String, body: [String]) -> [String] {
		let normalized = name.lowercased()
		let alertType: String
		switch normalized {
		case "note", "info":          alertType = "NOTE"
		case "tip", "success", "hint": alertType = "TIP"
		case "warning", "warn":       alertType = "WARNING"
		case "caution":               alertType = "CAUTION"
		case "danger", "error":       alertType = "IMPORTANT"
		case "important":             alertType = "IMPORTANT"
		default:                      alertType = "NOTE"
		}
		var lines: [String] = ["> [!\(alertType)]"]
		for body in body {
			let trimmed = body.trimmingCharacters(in: .whitespaces)
			lines.append(trimmed.isEmpty ? ">" : "> \(trimmed)")
		}
		return lines
	}
}
