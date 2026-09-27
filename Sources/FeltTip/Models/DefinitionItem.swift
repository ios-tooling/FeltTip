//
//  DefinitionItem.swift
//  FeltTip
//

import Foundation

public struct DefinitionItem: Sendable {
	public let term: String
	public let definitions: [String]

	public init(term: String, definitions: [String]) {
		self.term = term
		self.definitions = definitions
	}
}
