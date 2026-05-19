# Spec coverage audit

How MarkDownRange compares to the published markdown specs we target:

- **CommonMark 0.31.2** — https://spec.commonmark.org/0.31.2/
- **GitHub Flavored Markdown (GFM)** — https://github.github.com/gfm/

Status key: ✅ implemented and matches spec · ⚠️ partial / known divergence · ❌ not implemented.

## Architecture summary

Parsing is layered:

1. **Preprocess** (`MarkdownPreprocessor`) — text passes through citations, footnotes, heading-space injection, abbreviations, custom containers, super/sub, inserted text, emoticons, smart quotes, smart typography, emoji shortcodes, highlight syntax, definition lists, and wikilinks. None of these are CommonMark or GFM features; they're extensions we layer on top of the body before parsing.
2. **Parse** (Apple's `swift-markdown` ≥ 0.4.0) — handles the actual CommonMark + GFM grammar. Anything in this section that says "matches" is in practice "matches because swift-markdown matches."
3. **Walk** (`BlockBuilder` + `InlineBuilder`) — convert `swift-markdown`'s AST into our `MarkdownBlock` cases and `AttributedString` runs.
4. **Post-process** — `convertHTMLTables`, `convertHTMLInlines`, `convertPreBlocks`, `groupDetailsBlocks`, `convertAlerts`, `convertDefinitionLists`.

Two notes that affect the entire audit:

- The preprocessor is invasive. It runs **before** the CommonMark parser, so any extension token that looks like literal text to CommonMark gets rewritten into something CommonMark *can* parse (HTML tags, links, etc.). The trade-off is that extension tokens sitting inside code fences need to be skipped explicitly by each processor — we do that for emoji, highlight, super/sub, etc., but a regression there would silently corrupt source code samples.
- `MarkdownBlockParser.parse` has a `preprocessed: Bool` flag. When `true` it skips `MarkdownPreprocessor` entirely and trusts the caller (only `FormattedMarkdownScreen` does this so it can keep footnote/citation handles for side panels). All other call sites get the full pipeline.

---

## CommonMark 0.31.2

### 2 — Preliminaries

| § | Feature | Status | Notes |
|---|---------|--------|-------|
| 2.1 | Characters and lines | ✅ | Delegated to swift-markdown. Line endings, blank lines, and Unicode classification handled by the parser. |
| 2.2 | Tabs | ✅ | Delegated to swift-markdown — tab-to-column expansion happens inside the parser. We never touch tabs in the preprocessor. |
| 2.3 | Insecure characters | ✅ | swift-markdown substitutes U+0000 with U+FFFD per spec. |
| 2.4 | Backslash escapes | ✅ | swift-markdown. Verified indirectly by the InlineHTMLTests / HTMLEntityTests passing. |
| 2.5 | Entity and numeric character references | ✅ | swift-markdown for in-body text. `HTMLEntityTests` covers `&lt;`, `&gt;`, `&amp;`, `&nbsp;`, `&#39;`, hex/decimal numeric. We *also* decode entities a second time inside `HTMLAttributeParser.decodeEntities` for raw-HTML fall-through (e.g. inside `<pre>` blocks). |

### 3 — Blocks and inlines

| § | Feature | Status | Notes |
|---|---------|--------|-------|
| 3.1 | Precedence | ✅ | swift-markdown. Block-level beats inline; container nesting follows the spec. |
| 3.2 | Container blocks and leaf blocks | ✅ | swift-markdown. We don't introduce new container types at the parser level — our additions (`alert`, `details`, `aligned`) are produced post-walk. |

### 4 — Leaf blocks

| § | Feature | Status | Notes |
|---|---------|--------|-------|
| 4.1 | Thematic breaks | ✅ | `BlockBuilder.visitThematicBreak`. `SmartTypography` has an `isStructuralDashLine` guard so `---` and `***` aren't dash-typographied into em-dashes before parsing. |
| 4.2 | ATX headings | ⚠️ | swift-markdown is strict CommonMark (must have space after `#`). We layer **lenient mode** via `MarkdownOptions.headingsRequireSpaceAfterHash`. Default is *lenient* (`HeadingSpaceInjector` inserts a space between `#{1,6}` and the body when missing), which is a CommonMark divergence. Caps at 6 hashes, skips fenced code, leaves mid-line hashes alone (covered by `MarkdownOptionsTests`). |
| 4.3 | Setext headings | ✅ | swift-markdown. `HighlightSyntax` skips lines made of only `=`/whitespace so `===` underlines aren't mistaken for `==highlight==` syntax. |
| 4.4 | Indented code blocks | ✅ | swift-markdown. `IndentedCodeTests`. |
| 4.5 | Fenced code blocks | ✅ | swift-markdown. Language attribute is preserved on `.codeBlock(language:)`. All preprocessors that scan text skip fenced blocks. |
| 4.6 | HTML blocks | ✅ | swift-markdown emits `HTMLBlock`. We then post-process selected shapes: `<table>` → `.table`, `<dl>` → `.definitionList`, `<pre>` → `.codeBlock`, `<details>` → `.details`, `<div>`/`<p>` with images/anchors → image/imageRow/paragraph via `HTMLInlineConverter`. Unconverted HTML blocks render via `HTMLBlockView` (WebKit-backed). |
| 4.7 | Link reference definitions | ✅ | swift-markdown resolves shortcut/collapsed/full references. `LinkReferenceTests` covers all three forms plus titles. `SmartQuotes` explicitly skips link-reference definitions so `[ref]: url "Title"` titles aren't curled. |
| 4.8 | Paragraphs | ✅ | swift-markdown. `ParagraphTests`. |
| 4.9 | Blank lines | ✅ | swift-markdown. |

### 5 — Container blocks

| § | Feature | Status | Notes |
|---|---------|--------|-------|
| 5.1 | Block quotes | ✅ | swift-markdown. We add visual cues: stronger left bar, italic, tinted background (`BlockQuoteView`), and `.markdownBlockquoteDepth` attribute for nested-bar rendering inside `NSTextView`. `BlockQuoteTests`. |
| 5.2 | List items | ✅ | swift-markdown. Tight/loose, multi-paragraph, nested all preserved. `ListTests`, `NestedListTests`. |
| 5.3 | Lists | ✅ | swift-markdown. Ordered list start index preserved on `.orderedList(start:)`. |

### 6 — Inlines

| § | Feature | Status | Notes |
|---|---------|--------|-------|
| 6.1 | Code spans | ✅ | swift-markdown. `InlineBuilder.visitInlineCode` paints monospaced + `theme.codeForeground`. |
| 6.2 | Emphasis and strong emphasis | ✅ | swift-markdown handles `*`/`_` and intra-word rules. `InlineBuilder` tracks bold/italic flags during walk and emits matching font traits. |
| 6.3 | Links | ✅ | swift-markdown for all four forms (inline, full reference, collapsed, shortcut). `InlineBuilder.visitLink` rebuilds destination + title; `LinkInfo` carries the URL out for side-panels. Auto-linkify pass (`linkifyBareURLs`, `NSDataDetector`) adds bare URLs at finalize time — *off* via `linkifyURLs: false` if the caller wants strict CommonMark. |
| 6.4 | Images | ✅ | swift-markdown's `Image` plus HTML `<img>` handled by `extractInlineHTMLImage`. Images surfaced as their own block (not inline) so dimensions and QuickLook previews work. Width/height/alt preserved when present. |
| 6.5 | Autolinks | ✅ | swift-markdown handles `<https://…>` and `<email@…>` per CommonMark. The GFM "extended autolinks" (bare URLs, `www.foo`) sit on top — see GFM § below. |
| 6.6 | Raw HTML | ✅ | swift-markdown emits `InlineHTML` runs. `InlineBuilder.visitInlineHTML` styles a curated set (`<sup>`, `<sub>`, `<u>`, `<mark>`, `<kbd>`, `<s>`/`<del>`/`<strike>`, `<b>`/`<strong>`, `<i>`/`<em>`, `<code>`, `<br>`, `<abbr>`, `<a>`, `<img>`). Other tags pass through as text. |
| 6.7 | Hard line breaks | ✅ | swift-markdown. `LineBreak` → `\n` in attributed output. |
| 6.8 | Soft line breaks | ✅ | swift-markdown. `SoftBreak` → space (the renderer-preserved form, per spec note). |
| 6.9 | Textual content | ✅ | swift-markdown. |

---

## GFM extensions

GFM adds five sections on top of CommonMark. `swift-markdown` ships the first three (tables, task lists, strikethrough) natively; the last two we provide ourselves.

| § | Feature | Status | Notes |
|---|---------|--------|-------|
| 4.10 | Tables (extension) | ✅ | swift-markdown emits `Markdown.Table`. `BlockBuilder.visitTable` carries header row, body rows, and per-column alignment (`TableColumnAlignment.left/center/right/default`). Image-only cells are surfaced as `.image` table cells so they render as bitmaps, not alt text. `HTMLTableParser` parses raw `<table>` HTML blocks into the same `.table` case. `TableTests`. |
| 5.3 | Task list items (extension) | ✅ | swift-markdown's `ListItem.checkbox` is read in `visitOrderedList`/`visitUnorderedList`. Checkbox state and per-document index recorded on `ListItemContent` so toggles can write back through `CheckboxToggleAction`. `TaskListTests`. |
| 6.5 | Strikethrough (extension) | ✅ | swift-markdown emits `Strikethrough` nodes; `InlineBuilder.visitStrikethrough` toggles a flag that turns into `.strikethroughStyle = .single` on the run. Both `~~` and `~` accepted by upstream. |
| 6.9 | Autolinks (extension) | ⚠️ | We have bare-URL linkification via `NSDataDetector` in `InlineBuilder.linkifyBareURLs` (toggle-able via `linkifyURLs:`). This catches `https://`/`http://` URLs anywhere in text. **Divergences from GFM:** (a) we don't have GFM's `www.` autolinker — `www.example.com` without a scheme is *not* turned into a link; (b) email addresses are not auto-linked outside `<>`; (c) trailing punctuation trimming follows `NSDataDetector` heuristics, not GFM's explicit rules about trailing `?!.,:*_~`. For strict-spec URLs (with scheme) inside body text, behaviour matches. |
| 6.11 | Disallowed Raw HTML (extension) | ❌ | GFM filters `<title>`, `<textarea>`, `<style>`, `<xmp>`, `<iframe>`, `<noembed>`, `<noframes>`, `<script>`, `<plaintext>` to text. We do **not** filter. Whitelisted tags are styled; everything else falls through `HTMLBlockView` (WebKit) or renders as plain text in inline contexts. Acceptable for a local-trust editor but would need filtering before rendering untrusted content. |

---

## Our extensions beyond CommonMark + GFM

For completeness — these are features we add that are not in either spec:

| Feature | Source | Notes |
|---------|--------|-------|
| Footnotes (`[^id]`) | `MarkdownFootnote` + `MarkdownPreprocessor` | Inline references become superscript links; bodies are appended as a trailing section with `↩` back-links. Pandoc-style. |
| Definition lists (`Term\n: def`) | `DefinitionListProcessor` → `<dl>` → `.definitionList` | PHP-Markdown-Extra-style. |
| Abbreviations (`*[HTML]: HyperText...`) | `AbbreviationProcessor` → `<abbr title>` | Tooltip on hover (`toolTip` attribute). |
| Highlight (`==text==`) | `HighlightSyntax` → `<mark>` | Setext-`=` lines explicitly skipped. |
| Superscript (`^text^`) / Subscript (`~text~`) | `SuperSubProcessor` | Maps to Unicode super/subscript when chars allow; HTML `<sup>`/`<sub>` fallback otherwise. Skips `~~strike~~`. |
| Inserted text (`++text++`) | `InsertedTextProcessor` → `<u>` | Underline. |
| Emoji shortcodes (`:smile:`) | `EmojiShortcodes` | ~200 names. Skips fenced/inline code. |
| Emoticons (`:-)`, `;)`, `8-)` …) | `EmoticonShortcodes` | Word-boundary-anchored. |
| Smart quotes / typography | `SmartQuotes`, `SmartTypography` | `--` → en-dash, `---` → em-dash, `...` → `…`, `(c)` → `©`, `(r)`, `(tm)`, `(p)`, `+-` → `±`. Skips link-reference titles, HTML attributes, structural dash lines. |
| Custom containers (`::: warning`) | `CustomContainerProcessor` | Converts to GFM-style `[!WARNING]` alerts. |
| Wikilinks (`[[Page]]`, `[[Page\|Alias]]`) | `WikilinkProcessor` | Obsidian/Bear-style. |
| Citations | `Citation` | Pandoc-style. |
| Frontmatter | `MarkdownBlockParser.extractFrontmatter` | YAML key-value parsed off the top; strict key validation prevents arbitrary `---`-bracketed prose from being eaten. |
| GFM-style alerts (`> [!NOTE]`, `[!TIP]`, `[!WARNING]`, `[!IMPORTANT]`, `[!CAUTION]`) | `convertAlerts` | We accept these even though they're a GitHub UI feature, not part of the published GFM spec. |
| Heading lenient mode | `MarkdownOptions.headingsRequireSpaceAfterHash = false` | CommonMark divergence: `##Heading` (no space) is promoted to a heading. Opt-out available. |

---

## Known gaps worth tracking

1. **GFM disallowed raw HTML** — no filtering of `<script>`, `<style>`, `<iframe>`, etc. Not safe for untrusted input as-is. (See § 6.11 above.)
2. **GFM extended autolinks** — `www.` prefix and bare email autolinking are not implemented; URL trailing-punctuation handling is `NSDataDetector`'s, not GFM's.
3. **Lenient ATX headings as default** — diverges from CommonMark. Intentional, but flag-gated; consumers can opt back into strict mode.
4. **Smart-typography is irreversible** — once `--` becomes `–`, the source no longer round-trips. Acceptable for a renderer; would need rethinking for a tool that re-serializes parsed AST.
