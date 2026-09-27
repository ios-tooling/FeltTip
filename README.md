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

## Migrating from MarkDownRange

This is a breaking package and module rename. Update the package URL, product dependencies, and `import MarkDownRange` / `@testable import MarkDownRange` statements to `FeltTip`. In Xcode, replace the old package product references and select the new product for each consuming target.

| Previous name | FeltTip name |
| --- | --- |
| `Sources/MarkDownRange` | `Sources/FeltTip` |
| `Tests/MarkDownRangeTests` | `Tests/FeltTipTests` |
| `MarkDownRange-Package` scheme | `FeltTip-Package` scheme |
| `AttributeScopes.MarkDownRangeAttributes` | `AttributeScopes.FeltTipAttributes` |
| `AttributeScopes.markDownRange` | `AttributeScopes.feltTip` |
| `MarkDownRangeInlineFontTraits` attribute key | `FeltTipInlineFontTraits` |
| `MarkDownRangeSourceOffset` attribute key | `FeltTipSourceOffset` |
| `MDRDebugEditing` user default | `FeltTipDebugEditing` |
| `MDR_*` test environment variables | `FELTTIP_*` (same suffix) |
| `mdr-change-marker` DOM class | `felttip-change-marker` |

Consumers that persist custom attributed-string keys must migrate the old key names or regenerate those attributed strings. Update custom DOM selectors and diagnostic launch settings if used. No compatibility aliases are provided.

Checkout folder names are independent of the Swift module name; an existing local checkout can retain its current folder name. The rendering skill uses paths relative to the active checkout.

## Development

```sh
swift test
Scripts/test-ios.sh
Scripts/test-benchmarks.sh
```

The iOS script accepts a simulator name or UDID. Wall-clock performance gates and soak tests are opt-in; for example, use `FELTTIP_SOAK=1 swift test --filter EditBridgeSoakTests` for the editing soak suite.
