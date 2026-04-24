//
//  MarkdownAccessoryButton.swift
//  MarkDownRange
//

import SwiftUI

public struct MarkdownAccessoryButton: View {
	let systemImage: String
	let tint: Color?
	let theme: MarkdownTheme
	let action: () -> Void

	public init(systemImage: String, tint: Color? = nil, theme: MarkdownTheme, action: @escaping () -> Void) {
		self.systemImage = systemImage
		self.tint = tint
		self.theme = theme
		self.action = action
	}

	public var body: some View {
		Button(action: action) {
			Image(systemName: systemImage)
				.font(.system(size: 12))
				.foregroundStyle(tint ?? theme.secondaryColor)
				.padding(6)
				.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
		}
		.buttonStyle(.plain)
	}
}
