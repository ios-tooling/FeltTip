//
//  ListBlockView.swift
//  MarkdownRendering
//

import SwiftUI

struct ListBlockView: View {
	let items: [ListItemContent]
	let ordered: Bool
	let start: Int
	let theme: MarkdownTheme
	let fontSize: CGFloat
	let baseURL: URL?
	let onLinkHover: ((String?) -> Void)?
	@Environment(\.onCheckboxToggle) private var onCheckboxToggle
	@Environment(\.onFocusChecklist) private var onFocusChecklist
	@Environment(\.onAddChecklistItem) private var onAddChecklistItem
	@State private var isContentHovering = false
	@State private var isTopButtonHovering = false
	@State private var isBottomButtonHovering = false

	private var isHovering: Bool { isContentHovering || isTopButtonHovering || isBottomButtonHovering }
	private var isChecklist: Bool { items.contains { $0.checkbox != nil } }

	var body: some View {
		let content = VStack(alignment: .leading, spacing: 4) {
			ForEach(Array(items.enumerated()), id: \.offset) { index, item in
				row(for: item, index: index)
			}
		}
		.padding(.leading, 8)
		.frame(maxWidth: .infinity, alignment: .leading)

		// Only attach hover tracking + animation for checklists, where the hover
		// state actually drives accessory buttons. For plain bullet/ordered lists
		// the modifier would re-evaluate this view's body on every cursor enter/
		// exit during scroll, rebuilding the entire ForEach for no visible reason.
		if isChecklist {
			content
				.contentShape(Rectangle())
				.onHover { isContentHovering = $0 }
				.overlay(alignment: .topTrailing) {
					if let onFocusChecklist {
						MarkdownAccessoryButton(systemImage: "rectangle.compress.vertical", theme: theme, label: "Focus checklist") {
							onFocusChecklist(itemTexts())
						}
						.padding(12)
						.opacity(isHovering ? 1 : 0)
						.allowsHitTesting(isHovering)
						.onHover { isTopButtonHovering = $0 }
					}
				}
				.overlay(alignment: .bottomTrailing) {
					if let onAddChecklistItem {
						MarkdownAccessoryButton(systemImage: "plus", theme: theme, label: "Add checklist item") {
							onAddChecklistItem(itemTexts())
						}
						.padding(12)
						.opacity(isHovering ? 1 : 0)
						.allowsHitTesting(isHovering)
						.onHover { isBottomButtonHovering = $0 }
					}
				}
				.animation(.easeInOut(duration: 0.15), value: isHovering)
		} else {
			content
		}
	}

	@ViewBuilder private func row(for item: ListItemContent, index: Int) -> some View {
		if let checkbox = item.checkbox {
			rowContent(for: item, index: index)
				.accessibilityElement(children: .combine)
				.accessibilityLabel(itemText(for: item))
				.accessibilityValue(checkbox == .checked ? "checked" : "unchecked")
				.accessibilityAddTraits(.isButton)
				.accessibilityAction(.default) { toggleFromRow(item) }
		} else {
			rowContent(for: item, index: index)
		}
	}

	@ViewBuilder private func rowContent(for item: ListItemContent, index: Int) -> some View {
		HStack(alignment: .firstTextBaseline, spacing: 6) {
			bulletOrCheckbox(index: index, item: item)
				.frame(minWidth: 20, alignment: .trailing)

			let blocks = VStack(alignment: .leading, spacing: 4) {
				ForEach(item.blocks) { block in
					MarkdownContentView.blockView(for: block, theme: theme, fontSize: fontSize, baseURL: baseURL, onLinkHover: onLinkHover)
				}
			}
			.environment(\.markdownTextSelectionEnabled, item.checkbox == nil)

			// Only install the tap responder for checkbox rows. Plain rows had
			// .contentShape + .onTapGesture installed for every item, each adding
			// an AppKit tracking area that gets revalidated on every scroll frame.
			if item.checkbox != nil {
				blocks
					.contentShape(Rectangle())
					.onTapGesture { toggleFromRow(item) }
			} else {
				blocks
			}
		}
	}

	private func itemText(for item: ListItemContent) -> String {
		for block in item.blocks {
			if case .paragraph(let content, _, _) = block {
				return String(content.characters)
			}
		}
		return "List item"
	}

	private func toggleFromRow(_ item: ListItemContent) {
		guard let checkbox = item.checkbox, let onCheckboxToggle, let index = item.checkboxIndex else { return }
		onCheckboxToggle(index, checkbox != .checked)
	}

	private func itemTexts() -> [String] {
		items.map { item in
			for block in item.blocks {
				if case .paragraph(let content, _, _) = block {
					return String(content.characters)
				}
			}
			return ""
		}
	}

	@ViewBuilder private func bulletOrCheckbox(index: Int, item: ListItemContent) -> some View {
		if let checkbox = item.checkbox {
			let isChecked = checkbox == .checked
			if let onCheckboxToggle, let checkboxIndex = item.checkboxIndex {
				Button {
					onCheckboxToggle(checkboxIndex, !isChecked)
				} label: {
					checkboxImage(isChecked: isChecked)
				}
				.buttonStyle(.plain)
			} else {
				checkboxImage(isChecked: isChecked)
			}
		} else if ordered {
			Text("\(start + index).")
				.font(.system(size: fontSize))
				.foregroundStyle(theme.secondaryColor)
		} else {
			Text("\u{2022}")
				.font(.system(size: fontSize))
				.foregroundStyle(theme.secondaryColor)
		}
	}

	private func checkboxImage(isChecked: Bool) -> some View {
		Image(systemName: isChecked ? "checkmark.square.fill" : "square")
			.font(.system(size: fontSize * 1.1))
			.foregroundStyle(isChecked ? theme.linkColor : theme.secondaryColor)
	}
}
