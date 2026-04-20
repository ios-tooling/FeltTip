// swift-tools-version: 6.0

import PackageDescription

let package = Package(
	name: "MarkDownRange",
	platforms: [.macOS(.v14), .iOS(.v17)],
	products: [
		.library(name: "MarkDownRange", targets: ["MarkDownRange"]),
		.library(name: "MarkdownSyntaxHighlighting", targets: ["MarkdownSyntaxHighlighting"]),
	],
	dependencies: [
		.package(url: "https://github.com/swiftlang/swift-markdown", from: "0.4.0"),
		.package(url: "https://github.com/ios-tooling/Convey", from: "3.0.0"),
		.package(url: "https://github.com/ios-tooling/SharedSettings", from: "1.0.7"),
	],
	targets: [
		.target(name: "MarkdownSyntaxHighlighting"),
		.target(
			name: "MarkDownRange",
			dependencies: [
				"MarkdownSyntaxHighlighting",
				.product(name: "Markdown", package: "swift-markdown"),
				.product(name: "Convey", package: "Convey"),
			],
			resources: [.copy("Resources")]
		),
		.testTarget(name: "MarkDownRangeTests", dependencies: ["MarkDownRange"]),
	]
)
