---
name: match-rendering
description: Iterate MarkDownRange's SwiftUI rendering until it matches a ground-truth markdown render. Takes either raw markdown or a URL/path to a .md file, captures both a reference render (via GitHub's POST /markdown API) and our SwiftUI render (via the Marker snapshot test harness), then iterates on MarkDownRange source to close the visual gap. Use when the user says "match the rendering", "make our render look like GitHub", "iterate on this markdown rendering", or supplies a markdown file with a complaint about how it looks.
---

# match-rendering

Drives a render → diff → fix loop for MarkDownRange's SwiftUI rendering pipeline. The harness lives in the consuming Marker app at `~/Documents/ManagedProjects/MacDev/Marker/MarkerTests/Snapshots/`; this skill orchestrates it.

## Inputs

The user provides one of:
- **Raw markdown** — paste or attach a `.md` file path
- **URL** — a remote `.md` (e.g., a GitHub raw URL); fetch with `curl -sSL`
- **Local path** — `.md` file already on disk

## What "match" means

Reference rendering = GitHub's canonical GFM HTML (POST `https://api.github.com/markdown` with `mode: "gfm"`), styled with `github-markdown-css`, rendered in WKWebView. This is the same output github.com produces for a README, so matching it means our SwiftUI render visually agrees with what users see on GitHub.

> Note: the user originally asked for `markdownlivepreview.com` as the reference. That site uses Monaco loaded as an ES module with no `window` handle, so driving it from `evaluateJavaScript` is fragile. GitHub's API is the cleaner ground truth and matches what the user usually wants anyway. If you ever need markdownlivepreview specifically, mention this trade-off and propose GitHub instead.

## The loop

### 1. Park the markdown as a fixture

```
~/Documents/ManagedProjects/MacDev/Marker/MarkerTests/Snapshots/Fixtures/<slug>.md
```

Slug is short and kebab-cased (e.g. `tailwind-readme`, `vue-readme`). Overwrite if it exists.

### 2. Add or reuse a test case

`~/Documents/ManagedProjects/MacDev/Marker/MarkerTests/Snapshots/ImageRenderingSnapshotTests.swift` already has a `renderPair(name:width:height:)` helper — add one `@Test` per fixture:

```swift
@Test("<slug> matches GitHub render")
func <camelCaseSlug>() async throws {
    try await renderPair(name: "<slug>", width: 760, height: 1100)
}
```

`renderPair` produces two PNGs side by side: `<slug>.png` (ours) and `<slug>.reference.png` (GitHub's).

### 3. Run the test

```bash
xcodebuild test \
  -scheme Marker \
  -destination 'platform=macOS' \
  -only-testing:MarkerTests/ImageRenderingSnapshotTests/<camelCaseSlug> \
  2>&1 | grep -E "passed|failed|Caught error"
```

Working directory must be `~/Documents/ManagedProjects/MacDev/Marker`.

### 4. Read both PNGs

Output sits in the sandboxed cache:
```
~/Library/Containers/com.standalone.Marker/Data/Library/Caches/MarkerSnapshots/
  <slug>.png             ← our SwiftUI render
  <slug>.reference.png   ← GitHub's render
```

Use `Read` on both. Visually diff:
- Block ordering and spacing
- Inline image rows vs. stacked images
- Image clipping or scaling
- Heading sizes / colors
- Link colors, code-block background, blockquote bar
- Table layout, list indentation, alignment

### 5. Fix in MarkDownRange

Source lives at `~/Documents/ManagedProjects/Frameworks/MarkDownRange/Sources/MarkDownRange/`. Common landing zones for visual fixes:

| Symptom | File |
|---|---|
| `<p>`, `<picture>`, `<source>`, `<div align>` HTML inline issues | `Processing/HTMLInlineConverter.swift` |
| `<img>` collection / batching | `Processing/ImageRegions.swift` |
| Image sizing, aspect, SVG clipping | `Views/ScaleDownImage.swift`, `Views/SVGImageView.swift`, `Views/ImageBlockView.swift` |
| Image rows / inline alignment | `Views/ImageRowView.swift`, `Views/MarkdownContentView.swift` (`.aligned`) |
| Headings, paragraphs, lists, tables | `Views/HeadingBlockView.swift`, `Views/ParagraphBlockView.swift`, `Views/ListBlockView.swift`, `Views/TableBlockView.swift` |
| Block dispatch | `Views/MarkdownContentView.swift` |
| Markdown → block parsing | `Parser/BlockBuilder.swift`, `Parser/InlineBuilder.swift`, `Models/MarkdownBlock.swift` |

After each edit, **re-run only the snapshot test for the active fixture** (step 3) and re-read the PNGs. Don't touch ImageRowView/ScaleDownImage in the same pass as a parser change unless they're causally linked — small steps make regressions obvious.

### 6. Stop conditions

Stop when the diff is "close enough":
- Block structure matches (no stacked-vs-inline mismatches)
- Images render uncropped at sane sizes
- Heading hierarchy + spacing reads the same at a glance

Don't chase pixel parity — the SwiftUI text engine and WebKit will never produce identical kerning. Document any deliberate deviations in the test's doc-comment.

## Adding a new fixture from scratch (full example)

User: "make this README render right: https://raw.githubusercontent.com/vuejs/core/main/README.md"

```bash
# 1. Fetch
curl -sSL https://raw.githubusercontent.com/vuejs/core/main/README.md \
  > ~/Documents/ManagedProjects/MacDev/Marker/MarkerTests/Snapshots/Fixtures/vue-readme.md
```

Then add to `ImageRenderingSnapshotTests.swift`:
```swift
@Test("Vue README matches GitHub render")
func vueReadme() async throws {
    try await renderPair(name: "vue-readme", width: 760, height: 1400)
}
```

Run:
```bash
cd ~/Documents/ManagedProjects/MacDev/Marker
xcodebuild test -scheme Marker -destination 'platform=macOS' \
  -only-testing:MarkerTests/ImageRenderingSnapshotTests/vueReadme
```

Read both:
- `~/Library/Containers/com.standalone.Marker/Data/Library/Caches/MarkerSnapshots/vue-readme.png`
- `~/Library/Containers/com.standalone.Marker/Data/Library/Caches/MarkerSnapshots/vue-readme.reference.png`

Iterate on MarkDownRange source until they match. Each round: edit → run test → read both PNGs.

## Notes

- The first run of a new test takes ~10s (page load + build). Subsequent runs are faster because builds are incremental.
- GitHub's API is rate-limited (60 req/hr unauthenticated). For heavy iteration, the `.reference.png` is cached on disk — you only need to rerun the reference capture when the fixture itself changes.
- If GitHub returns 422, the markdown is malformed; check the fixture.
- The harness writes both PNGs regardless of pass/fail. If the test fails, read whatever was produced before the failure to debug.
