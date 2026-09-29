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

	public init(
		term: String,
		definitions: [String],
		termSourceStart: Int? = nil,
		definitionSourceStarts: [Int?] = []
	) {
		self.term = term
		self.definitions = definitions
		self.termSourceStart = termSourceStart
		self.definitionSourceStarts = definitionSourceStarts
	}
}
