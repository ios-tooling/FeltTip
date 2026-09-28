//
//  AlertType.swift
//  FeltTip
//

import SwiftUI

public enum AlertType: String, Sendable, CaseIterable {
	case note, tip, important, warning, caution

	public var label: String {
		rawValue.capitalized
	}

	public var icon: String {
		switch self {
		case .note: "info.circle.fill"
		case .tip: "lightbulb.fill"
		case .important: "exclamationmark.circle.fill"
		case .warning: "exclamationmark.triangle.fill"
		case .caution: "flame.fill"
		}
	}

	public var color: Color {
		switch self {
		case .note: .blue
		case .tip: .green
		case .important: .purple
		case .warning: .yellow
		case .caution: .red
		}
	}

	public init?(from text: String) {
		let key = text.trimmingCharacters(in: .whitespaces).lowercased()
		if let match = Self.allCases.first(where: { $0.rawValue == key }) {
			self = match
		} else {
			return nil
		}
	}
}
