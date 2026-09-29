// swift-tools-version: 6.0

import PackageDescription

let package = Package(
	name: "FeltTip",
	platforms: [.macOS("26.0"), .iOS(.v18)],
	products: [
		.library(name: "FeltTip", targets: ["FeltTip"]),
		.library(name: "MarkdownSyntaxHighlighting", targets: ["MarkdownSyntaxHighlighting"]),
	],
	dependencies: [
		.package(url: "https://github.com/swiftlang/swift-markdown", from: "0.4.0"),
		.package(url: "https://github.com/ios-tooling/Convey", from: "3.0.0"),
		.package(url: "https://github.com/ios-tooling/JohnnyCache.git", from: "1.0.14"),
		.package(url: "https://github.com/ios-tooling/SharedSettings", from: "1.0.10"),
		.package(url: "https://github.com/ios-tooling/FunnelVision", branch: "main"),
		.package(url: "https://github.com/ios-tooling/CrossPlatformKit", from: "1.1.4"),
	],
	targets: [
		.target(name: "MarkdownSyntaxHighlighting"),
		.target(
			name: "FeltTip",
			dependencies: [
				"MarkdownSyntaxHighlighting",
				.product(name: "Markdown", package: "swift-markdown"),
				.product(name: "Convey", package: "Convey"),
				.product(name: "JohnnyCache", package: "JohnnyCache"),
				.product(name: "SharedSettings", package: "SharedSettings"),
				.product(name: "FunnelVision", package: "FunnelVision"),
				.product(name: "CrossPlatformKit", package: "CrossPlatformKit"),
			],
			exclude: ["Rendering/EDITING.md"],
			// Each file is copied individually rather than `.copy("Resources")`.
			// A directory copy nests them inside a `Resources/` subfolder, and
			// codesign rejects that layout in an iOS bundle ("bundle format
			// unrecognized"), which blocks every signed iOS build.
			resources: [
				.copy("Resources/CheckboxScript.js"),
				.copy("Resources/EditorScript.js"),
				.copy("Resources/FocusModeScript.js"),
				.copy("Resources/ImagePresentationScript.js"),
				.copy("Resources/LinkPreviewScript.js"),
				.copy("Resources/ScrollSyncScript.js"),
				.copy("Resources/mermaid-template.html"),
				.copy("Resources/mermaid.min.js"),
			]
		),
		.testTarget(
			name: "FeltTipTests",
			dependencies: ["FeltTip"],
			// The large sample is accessed by `#filePath`, not bundled as a
			// compiled test resource.
			exclude: ["Fixtures/SuperDuper-0.6.0.md"]
		),
	]
)
