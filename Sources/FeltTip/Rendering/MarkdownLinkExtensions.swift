//
//  MarkdownLinkExtensions.swift
//  FeltTip
//
//  Filename extensions the renderers treat as internal Markdown links (so a
//  click opens them in-app rather than externally). Kept in sync with the
//  app's MarkdownFolderScanner / Info.plist UTI declarations, which live in a
//  separate module this framework can't import.
//

import Foundation

enum MarkdownLinkExtensions {
	static let all: Set<String> = [
		"md", "markdown", "mdown", "mkd", "mkdn", "mkdown", "mdwn",
		"mdx", "rmd", "qmd", "mdoc", "mdc", "livemd"
	]
}
