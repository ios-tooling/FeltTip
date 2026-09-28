# Spec coverage audit

How FeltTip compares to the published markdown specs we target:

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

| § | Feature | Status | Test | Notes |
|---|---------|--------|------|-------|
| 2.1 | Characters and lines | ✅ | (covered indirectly by every parser test) | Delegated to swift-markdown. Line endings, blank lines, and Unicode classification handled by the parser. |
| 2.2 | Tabs | ✅ | `TabExpansionTests` (4) · `IndentedCodeTests.tabIndentedCode` | Delegated to swift-markdown — tab-to-column expansion happens inside the parser. We never touch tabs in the preprocessor. |
| 2.3 | Insecure characters | ✅ | `InsecureCharacterTests` (2) | swift-markdown substitutes U+0000 with U+FFFD per spec. |
| 2.4 | Backslash escapes | ✅ | `BackslashEscapesTests` (7) · `MarkdownItParityTests.commonMark_escapedCharacter` | swift-markdown. Asterisks, underscores, brackets, backticks, the backslash itself, and the rule that non-punctuation escapes are literal. |
| 2.5 | Entity and numeric character references | ✅ | `EntityReferenceTests` (7) · `HTMLEntityTests` (5) · `MarkdownItParityTests.commonMark_entityReference` | swift-markdown for in-body text. We *also* decode entities a second time inside `HTMLAttributeParser.decodeEntities` for raw-HTML fall-through (e.g. inside `<pre>` blocks). |

### 3 — Blocks and inlines

| § | Feature | Status | Test | Notes |
|---|---------|--------|------|-------|
| 3.1 | Precedence | ✅ | (covered combinatorially by block/inline tests) | swift-markdown. Block-level beats inline; container nesting follows the spec. |
| 3.2 | Container blocks and leaf blocks | ✅ | `BlockQuoteTests.blockQuoteWithList` · `NestedListTests` | swift-markdown. We don't introduce new container types at the parser level — our additions (`alert`, `details`, `aligned`) are produced post-walk. |

### 4 — Leaf blocks

| § | Feature | Status | Test | Notes |
|---|---------|--------|------|-------|
| 4.1 | Thematic breaks | ✅ | `ThematicBreakTests` (5) · parity | `BlockBuilder.visitThematicBreak`. `SmartTypography` has an `isStructuralDashLine` guard so `---` and `***` aren't dash-typographied into em-dashes before parsing. |
| 4.2 | ATX headings | ⚠️ | `HeadingTests` (11) · `MarkdownOptionsTests` (9) · parity | swift-markdown is strict CommonMark (must have space after `#`). We layer **lenient mode** via `MarkdownOptions.headingsRequireSpaceAfterHash`. Default is *lenient* (`HeadingSpaceInjector` inserts a space between `#{1,6}` and the body when missing), which is a CommonMark divergence. Caps at 6 hashes, skips fenced code, leaves mid-line hashes alone. |
| 4.3 | Setext headings | ✅ | `HeadingTests.setextH2` · `MarkdownItParityTests.commonMark_setextHeadings` | swift-markdown. `HighlightSyntax` skips lines made of only `=`/whitespace so `===` underlines aren't mistaken for `==highlight==` syntax. |
| 4.4 | Indented code blocks | ✅ | `IndentedCodeTests` (4) · parity | swift-markdown. |
| 4.5 | Fenced code blocks | ✅ | `CodeBlockTests` (6) · parity | swift-markdown. Language attribute is preserved on `.codeBlock(language:)`. All preprocessors that scan text skip fenced blocks. |
| 4.6 | HTML blocks | ✅ | `HTMLBlockTests` (5) · `HTMLDivAndImageTests` (6) · parity | swift-markdown emits `HTMLBlock`. We then post-process selected shapes: `<table>` → `.table`, `<dl>` → `.definitionList`, `<pre>` → `.codeBlock`, `<details>` → `.details`, `<div>`/`<p>` with images/anchors → image/imageRow/paragraph via `HTMLInlineConverter`. Unconverted HTML blocks render via `HTMLBlockView`, which decodes HTML through `NSAttributedString` (no WebKit, no JavaScript execution path). |
| 4.7 | Link reference definitions | ✅ | `LinkReferenceTests` (5) · parity | swift-markdown resolves shortcut/collapsed/full references. `SmartQuotes` explicitly skips link-reference definitions so `[ref]: url "Title"` titles aren't curled. |
| 4.8 | Paragraphs | ✅ | `ParagraphTests` (13) · parity | swift-markdown. |
| 4.9 | Blank lines | ✅ | `BlankLineTests` (4) | swift-markdown. Leading/trailing blanks ignored, multiple internal blanks collapse to a single separator. |

### 5 — Container blocks

| § | Feature | Status | Test | Notes |
|---|---------|--------|------|-------|
| 5.1 | Block quotes | ✅ | `BlockQuoteTests` (5) · parity | swift-markdown. We add visual cues: stronger left bar, italic, tinted background (`BlockQuoteView`), and `.markdownBlockquoteDepth` attribute for nested-bar rendering inside `NSTextView`. |
| 5.2 | List items | ✅ | `ListTests` (8) · `NestedListTests` (4) | swift-markdown. Tight/loose, multi-paragraph, nested all preserved. |
| 5.3 | Lists | ✅ | `ListTests` · parity | swift-markdown. Ordered list start index preserved on `.orderedList(start:)`. |

### 6 — Inlines

| § | Feature | Status | Test | Notes |
|---|---------|--------|------|-------|
| 6.1 | Code spans | ✅ | `ParagraphTests.inlineCode` · `AttributedStringBuilderTests.inlineCodeProducesMonospacedFont` · parity | swift-markdown. `InlineBuilder.visitInlineCode` paints monospaced + `theme.codeForeground`. |
| 6.2 | Emphasis and strong emphasis | ✅ | `ParagraphTests.{boldText,italicText,boldItalic}` · `AttributedStringBuilderTests.{inlineBold,inlineItalic}ProducesBoldFont` · parity | swift-markdown handles `*`/`_` and intra-word rules. `InlineBuilder` tracks bold/italic flags during walk and emits matching font traits. |
| 6.3 | Links | ✅ | `LinkReferenceTests` (5) · `AutolinkTests.{explicitMarkdownLink,linkInParagraph,multipleLinksSameLineParagraph}` · parity | swift-markdown for all four forms (inline, full reference, collapsed, shortcut). Auto-linkify pass (`linkifyBareURLs`, `NSDataDetector`) adds bare URLs at finalize time — *off* via `linkifyURLs: false` if the caller wants strict CommonMark. |
| 6.4 | Images | ✅ | `ImageTests` (4) · `MarkdownImageSizingTests` · parity | swift-markdown's `Image` plus HTML `<img>` handled by `extractInlineHTMLImage`. Images surfaced as their own block (not inline) so dimensions and QuickLook previews work. |
| 6.5 | Autolinks | ✅ | `AutolinkTests.angleBracketAutolink` · `MarkdownItParityTests.commonMark_autolink` | swift-markdown handles `<https://…>` and `<email@…>` per CommonMark. The GFM extended autolinks sit on top — see GFM § below. |
| 6.6 | Raw HTML | ✅ | `InlineHTMLTests` (7) · `MarkdownItParityTests.commonMark_inlineHTML_underline` | swift-markdown emits `InlineHTML` runs. `InlineBuilder.visitInlineHTML` styles a curated set (`<sup>`, `<sub>`, `<u>`, `<mark>`, `<kbd>`, `<s>`/`<del>`/`<strike>`, `<b>`/`<strong>`, `<i>`/`<em>`, `<code>`, `<br>`, `<abbr>`, `<a>`, `<img>`). Other tags pass through as text. |
| 6.7 | Hard line breaks | ✅ | `ParagraphTests.hardBreak` · `InlineHTMLTests.lineBreak` | swift-markdown. `LineBreak` → `\n` in attributed output. |
| 6.8 | Soft line breaks | ✅ | `ParagraphTests.softBreakBecomesSpace` | swift-markdown. `SoftBreak` → space (the renderer-preserved form, per spec note). |
| 6.9 | Textual content | ✅ | (covered transitively by every paragraph/inline test) | swift-markdown. |

---

## GFM extensions

GFM adds five sections on top of CommonMark. `swift-markdown` ships the first three (tables, task lists, strikethrough) natively; the last two we provide ourselves.

| § | Feature | Status | Test | Notes |
|---|---------|--------|------|-------|
| 4.10 | Tables (extension) | ✅ | `TableTests` (4) · `HTMLBlockTests.htmlTableConvertedToTableBlock` · `MarkdownItParityTests.{gfm_table,gfm_tableRightAlignment}` | swift-markdown emits `Markdown.Table`. `BlockBuilder.visitTable` carries header row, body rows, and per-column alignment (`TableColumnAlignment.left/center/right/default`). Image-only cells are surfaced as `.image` table cells so they render as bitmaps, not alt text. `HTMLTableParser` parses raw `<table>` HTML blocks into the same `.table` case. |
| 5.3 | Task list items (extension) | ✅ | `TaskListTests` (5) · `MarkdownItParityTests.gfm_taskList` | swift-markdown's `ListItem.checkbox` is read in `visitOrderedList`/`visitUnorderedList`. Checkbox state and per-document index recorded on `ListItemContent` so toggles can write back through `CheckboxToggleAction`. |
| 6.5 | Strikethrough (extension) | ✅ | `ParagraphTests.strikethrough` · `MarkdownItParityTests.gfm_strikethrough` | swift-markdown emits `Strikethrough` nodes; `InlineBuilder.visitStrikethrough` toggles a flag that turns into `.strikethroughStyle = .single` on the run. Both `~~` and `~` accepted by upstream. |
| 6.9 | Autolinks (extension) | ✅ | `AutolinkTests` (7) · `WWWAutolinkTests` (13) · `MarkdownItParityTests.gfm_autolinkBareURL` | Two-pass linkification on the finalized inline string. `linkifyBareURLs` runs `NSDataDetector` for scheme-bearing URLs (`http://`, `https://`) and email patterns. `linkifyWWWPrefix` adds GFM's `www.`-prefix extension: matches `\bwww\.[…]+(?:\.[…])+(?:/…)?`, maps to `http://<run>`, strips trailing `?!.,:*_~` and unbalanced trailing `)` per GFM. Both passes skip ranges that already carry a link or sit inside a code-span / `<kbd>` (verbatim) region. Toggle-able via `linkifyURLs:`. |
| 6.11 | Disallowed Raw HTML (extension) | ❌ | — (not implemented) | GFM filters `<title>`, `<textarea>`, `<style>`, `<xmp>`, `<iframe>`, `<noembed>`, `<noframes>`, `<script>`, `<plaintext>` to text. We do **not** filter. Lower risk than it sounds for our renderer: `HTMLBlockView` uses `NSAttributedString` HTML decoding (no JavaScript execution); whitelisted tags are styled and the rest is rendered as plain styled text. Filtering would still be required if we ever pipe untrusted markdown through a WebKit surface. |

---

## Our extensions beyond CommonMark + GFM

For completeness — these are features we add that are not in either spec:

| Feature | Source | Test | Notes |
|---------|--------|------|-------|
| Footnotes (`[^id]`) | `MarkdownFootnote` + `MarkdownPreprocessor` | `MarkdownItParityTests.plugin_footnote_referenceLinksToBody` | Inline references become superscript links; bodies are appended as a trailing section with `↩` back-links. Pandoc-style. |
| Definition lists (`Term\n: def`) | `DefinitionListProcessor` → `<dl>` → `.definitionList` | `MarkdownItParityTests.plugin_definitionList` | PHP-Markdown-Extra-style. |
| Abbreviations (`*[HTML]: HyperText...`) | `AbbreviationProcessor` → `<abbr title>` | `MarkdownItParityTests.plugin_abbreviation` | Tooltip on hover (`toolTip` attribute). |
| Highlight (`==text==`) | `HighlightSyntax` → `<mark>` | `HighlightTests` (5) · `MarkdownItParityTests.plugin_mark` | Setext-`=` lines explicitly skipped. |
| Superscript (`^text^`) / Subscript (`~text~`) | `SuperSubProcessor` | `SuperSubProcessorTests` (9) · `MarkdownItParityTests.{plugin_super,plugin_sub}script_*` | Maps to Unicode super/subscript when chars allow; HTML `<sup>`/`<sub>` fallback otherwise. Skips `~~strike~~`. |
| Inserted text (`++text++`) | `InsertedTextProcessor` → `<u>` | `InsertedTextProcessorTests` (5) · `MarkdownItParityTests.plugin_insert` | Underline. |
| Emoji shortcodes (`:smile:`) | `EmojiShortcodes` | `EmojiTests` (8) · `MarkdownItParityTests.plugin_emoji` | ~200 names. Skips fenced/inline code. |
| Emoticons (`:-)`, `;)`, `8-)` …) | `EmoticonShortcodes` | `EmoticonShortcodesTests` (7) | Word-boundary-anchored. |
| Smart quotes / typography | `SmartQuotes`, `SmartTypography` | `SmartTypographyTests` (12) · `MarkdownItParityTests.typographer_*` (10) | `--` → en-dash, `---` → em-dash, `...` → `…`, `(c)` → `©`, `(r)`, `(tm)`, `(p)`, `+-` → `±`. Skips link-reference titles, HTML attributes, structural dash lines. |
| Custom containers (`::: warning`) | `CustomContainerProcessor` | `AlertBlockTests` (8) · `MarkdownItParityTests.plugin_customContainer` | Converts to GFM-style `[!WARNING]` alerts. |
| Wikilinks (`[[Page]]`, `[[Page\|Alias]]`) | `WikilinkProcessor` | `WikilinkProcessorTests` (8) | Obsidian/Bear-style. Covers pass-through, unclosed openers, empty brackets, multi-link lines, aliases, newline boundaries, percent-encoding. |
| Citations | `Citation` | `CitationTests` (10) | Pandoc-style. Covers single ref/def, renumber by first-appearance order, duplicate-ref collapse, missing-def drop, fence-ignored definitions, rendered output, parseDefinition edge cases. |
| Frontmatter | `MarkdownBlockParser.extractFrontmatter` | `FrontmatterTests` (10) | YAML key-value parsed off the top; strict key validation prevents arbitrary `---`-bracketed prose from being eaten. |
| GFM-style alerts (`> [!NOTE]`, `[!TIP]`, `[!WARNING]`, `[!IMPORTANT]`, `[!CAUTION]`) | `convertAlerts` | `AlertBlockTests` (8) | We accept these even though they're a GitHub UI feature, not part of the published GFM spec. |
| Heading lenient mode | `MarkdownOptions.headingsRequireSpaceAfterHash = false` | `MarkdownOptionsTests` (9) · `MarkdownSyntaxHighlighterTests` (6) | CommonMark divergence: `##Heading` (no space) is promoted to a heading. Opt-out available. |

---

## Known gaps worth tracking

1. **GFM disallowed raw HTML** — no filtering of `<script>`, `<style>`, `<iframe>`, etc. Lower risk than it sounds because `HTMLBlockView` decodes HTML through `NSAttributedString` (no JS execution path), but filtering would still be needed before piping untrusted markdown through a WebKit surface. (See § 6.11 above.)
2. **Lenient ATX headings as default** — diverges from CommonMark. Intentional, but flag-gated; consumers can opt back into strict mode.
3. **Smart-typography is irreversible** — once `--` becomes `–`, the source no longer round-trips. Acceptable for a renderer; would need rethinking for a tool that re-serializes parsed AST.
---

## Test files reference

| Suite | Tests | Covers |
|-------|-------|--------|
| `AlertBlockTests` | 8 | GFM-style `[!NOTE]/[!TIP]/[!WARNING]/[!IMPORTANT]/[!CAUTION]` alerts and `::: container` desugaring. |
| `AttributedStringBuilderTests` | 15 | Final attributed-string output — fonts, link bridging, code attachments, heading sizes. |
| `AutolinkTests` | 7 | CommonMark `<…>` autolinks + GFM bare-URL detection. |
| `BackslashEscapesTests` | 7 | CommonMark § 2.4 — escapes for `*`, `_`, `[`, `` ` ``, `\`, plus non-escape and code-span literals. |
| `BlankLineTests` | 4 | CommonMark § 4.9 — leading/trailing/multiple/separator blanks. |
| `BlockQuoteTests` | 5 | CommonMark § 5.1 — simple/multi-line/nested/with-code/with-list. |
| `CitationTests` | 10 | Pandoc-style `[@key]` references and `[@key]: …` definitions, with renumber and fence-skip rules. |
| `CodeBlockTests` | 6 | CommonMark § 4.5 — fenced (` ``` `, `~~~`), language tags, whitespace preservation. |
| `ComplexDocumentTests` | 9 | Integration of headings, lists, code, links across full documents. |
| `DetailsSummaryTests` | 4 | `<details>`/`<summary>` post-processing into `.details` blocks. |
| `EmojiTests` | 8 | Emoji shortcode pipeline including code-span exclusion. |
| `EmoticonShortcodesTests` | 7 | `:-)`, `:-(`, `;)`, `8-)`, word-boundary handling. |
| `EntityReferenceTests` | 7 | CommonMark § 2.5 — named, numeric decimal, numeric hex, in-link entities. |
| `FrontmatterTests` | 10 | YAML frontmatter strict-mode parser. |
| `HTMLAnchorImageTests` | 1 | `<a><img></a>` smoke test. |
| `HTMLBlockTests` | 5 | CommonMark § 4.6 — HTML block conversion, paragraph/table/linked-image. |
| `HTMLDivAndImageTests` | 6 | `<div>` + `<img>` post-processing (HTMLInlineConverter). |
| `HTMLEntityTests` | 5 | `HTMLAttributeParser.decodeEntities`. |
| `HeadingTests` | 11 | CommonMark §§ 4.2, 4.3 — ATX, setext, inline formatting, closing hashes. |
| `HighlightTests` | 5 | `==mark==` syntax. |
| `ImageTests` | 4 | CommonMark § 6.4 — solo, empty-alt, mixed, inline. |
| `IndentedCodeTests` | 4 | CommonMark § 4.4 — 4-space, tab-indented, whitespace preservation. |
| `InlineHTMLTests` | 7 | CommonMark § 6.6 — `<br>`, `<b>`, `<sup>`, `<sub>`, `<u>`, `<kbd>`. |
| `InsecureCharacterTests` | 2 | CommonMark § 2.3 — U+0000 substitution + leading-null safety. |
| `InsertedTextProcessorTests` | 5 | `++text++` → underline. |
| `LinkReferenceTests` | 5 | CommonMark § 4.7 — full/collapsed/shortcut/multiple/with-title. |
| `ListTests` | 8 | CommonMark §§ 5.2, 5.3 — `-`/`*`/`+` markers, ordered, start index, multi-paragraph items. |
| `MarkdownImageSizingTests` | 7 | Width/height parsing, aspect-ratio placeholders, viewport scaling. |
| `MarkdownItParityTests` | 46 | One-test-per-feature parity matrix against markdown-it (CommonMark + GFM + plugins + typographer). |
| `MarkdownMetaSampleTests` | 1 (920 cases) | `meta(for:)` driven over the entire `Misc/sample_markdowns/` corpus. |
| `MarkdownMetaTests` | 13 | `MarkdownMetaWalker` — heading outline, reading time, link inventory. |
| `MarkdownOptionsTests` | 9 | `headingsRequireSpaceAfterHash` strict vs lenient. |
| `MarkdownSyntaxHighlighterTests` | 6 | Raw-editor temporary-attribute highlighter; strict/lenient heading bolding; code-fence exclusion. |
| `NestedListTests` | 4 | Deeply nested list parsing. |
| `ParagraphTests` | 13 | CommonMark § 4.8 + § 6.7/§ 6.8 — paragraphs, soft/hard breaks, inline bold/italic/code/strike/link. |
| `PipelineBenchmarkTests` | 4 | Performance budget for the preprocess/parse/walk pipeline on medium/large samples. |
| `SVGDimensionTests` | 13 | SVG `viewBox` / explicit width/height parsing. |
| `SmartTypographyTests` | 12 | Smart quotes, dashes, ellipsis, ©®™℗±. |
| `SuperSubProcessorTests` | 9 | `^sup^`, `~sub~`, strike-skipping, HTML fallback. |
| `TabExpansionTests` | 4 | CommonMark § 2.2 — leading tab, list-marker tab, mid-text tab, mixed indent. |
| `TableTests` | 4 | GFM § 4.10 — simple, formatting, single-column, with-links. |
| `TaskListTests` | 5 | GFM § 5.3 — checked, unchecked, mixed, ordered with checkbox, regular unaffected. |
| `ThematicBreakTests` | 5 | CommonMark § 4.1 — `---`/`***`/`___`/with-spaces/between-paragraphs. |
| `ThemeTests` | 6 | Theme value-type behaviour. |
| `TokenizerTests` | 12 | HTML tokenizer/attribute parser primitives. |
| `WWWAutolinkTests` | 13 | GFM § 6.9 `www.`-prefix autolinker — bare URL, path, TLD requirement, trailing-punctuation strip, balanced/unbalanced paren rules, code-span / kbd skip, case-insensitive match. |
| `WikilinkProcessorTests` | 8 | Obsidian/Bear-style `[[Page]]` / `[[Page\|Alias]]` desugaring with percent-encoding. |

**Total: 375 tests across 48 suites.**
