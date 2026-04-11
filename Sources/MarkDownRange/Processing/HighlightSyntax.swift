//
//  HighlightSyntax.swift
//  MarkDownRange
//

import Foundation

public enum HighlightSyntax {
	public static func process(_ text: String) -> String {
		text.replacing(/==(.+?)==/) { "<mark>\($0.1)</mark>" }
	}
}
