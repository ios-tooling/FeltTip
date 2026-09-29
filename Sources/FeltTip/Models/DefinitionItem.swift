//
//  DefinitionItem.swift
//  FeltTip
//

import Foundation

public struct DefinitionItem: Sendable {
	public let term: String
	public let definitions: [String]
	public let termSourceStart: Int?
	public let definitionSourceStarts: [Int?]
	/// Original inline source before preprocessors synthesize render-only
	/// Markdown (for example, footnote links). Used to keep surviving runs
	/// editable while leaving synthesized runs unstamped.
	public let termSourceText: String?
	public let definitionSourceTexts: [String?]

	public init(
		term: String,
		definitions: [String],
		termSourceStart: Int? = nil,
		definitionSourceStarts: [Int?] = [],
		termSourceText: String? = nil,
		definitionSourceTexts: [String?] = []
	) {
		self.term = term
		self.definitions = definitions
		self.termSourceStart = termSourceStart
		self.definitionSourceStarts = definitionSourceStarts
		self.termSourceText = termSourceText
		self.definitionSourceTexts = definitionSourceTexts
	}
}
