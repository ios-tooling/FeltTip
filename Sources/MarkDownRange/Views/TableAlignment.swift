//
//  TableAlignment.swift
//  MarkDownRange
//

import SwiftUI

public enum TableAlignment: Sendable {
	/// Each column stretches equally so the table fills the available
	/// reading width. Default — matches typical document chrome where
	/// tables behave like other block-level elements.
	case fill
	/// Columns size to their content; the resulting table is positioned
	/// against the leading, centered, or trailing edge of its container.
	case leading, center, trailing

	var frameAlignment: Alignment {
		switch self {
		case .fill, .leading: return .leading
		case .center: return .center
		case .trailing: return .trailing
		}
	}
}

extension EnvironmentValues {
	@Entry public var tableAlignment: TableAlignment = .leading
}

/// Column-level alignment parsed from GFM table delimiter rows
/// (`:---`, `:---:`, `---:`). One value per column; unspecified columns use
/// `.default`, which defers to the consumer's natural alignment for the cell.
public enum TableColumnAlignment: Sendable {
	case `default`
	case left
	case center
	case right

	public var textAlignment: TextAlignment {
		switch self {
		case .left, .default: .leading
		case .center: .center
		case .right: .trailing
		}
	}

	public var frameAlignment: Alignment {
		switch self {
		case .left, .default: .leading
		case .center: .center
		case .right: .trailing
		}
	}
}
