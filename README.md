# FeltTip

FeltTip (pronounced “Felt Tip”) is a Swift Markdown rendering and editing framework for macOS 26 and iOS 18 or later. It includes WebKit rendering, source editing, syntax highlighting, and HTML/PDF export.

Repository: [ios-tooling/FeltTip](https://github.com/ios-tooling/FeltTip).

## Integration

Add `https://github.com/ios-tooling/FeltTip.git` as a Swift package dependency and select the `FeltTip` library product. In a consuming package target, use:

```swift
.product(name: "FeltTip", package: "FeltTip")
```

Import the framework with:

```swift
import FeltTip
```

The separate `MarkdownSyntaxHighlighting` product remains available. Markdown APIs such as `MarkdownWebView`, `MarkdownTheme`, and `MarkdownOptions` retain their names.

Checkout folder names are independent of the Swift module name; an existing local checkout can retain its current folder name. The rendering skill uses paths relative to the active checkout.

## Development

```sh
swift test
Scripts/test-ios.sh
Scripts/test-benchmarks.sh
```

The iOS script accepts a simulator name or UDID. Wall-clock performance gates and soak tests are opt-in; for example, use `FELTTIP_SOAK=1 swift test --filter EditBridgeSoakTests` for the editing soak suite.
