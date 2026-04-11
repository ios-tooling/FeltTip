//
//  LinkInfo.swift
//  MarkdownRendering
//

import Foundation

public struct LinkInfo: Sendable {
	public let url: String
	public let characterOffset: Int

	public init(url: String, characterOffset: Int) {
		self.url = url
		self.characterOffset = characterOffset
	}
}
