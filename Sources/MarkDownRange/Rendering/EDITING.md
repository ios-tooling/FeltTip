# Editing in the styled (web) view

How `MarkdownWebView` turns keystrokes in a `contentEditable` page into edits of
the **markdown source**, which is always the single source of truth. The page is
a projection of the source; it is never authoritative. Read this before changing
`EditorScript.js`, `MarkdownWebViewEditBridge`, `MarkdownWebViewCoordinator`, or
`MarkdownEditSplicer`.

## The invariant everything rests on

Every rendered run that came from verbatim source text carries a `data-s`
attribute holding its **UTF-16 source offset**:

> **A stamped run's text equals the source at its own stamp.**

Runs whose rendered form differs from their source (escapes, smart quotes,
entity references, trailing-space hard breaks) get **no stamp**, so the caret
there maps to nothing and the keystroke is vetoed rather than guessed at. Tests
assert the invariant directly via `CoordinatorBridgeHarness.stampMismatches()` —
add that assertion to any new editing test; it catches drift that happens to
leave the visible text correct.

Stamping verifies the rendered text itself, not only its length. For lazy list
continuations swift-markdown can report a virtual indented column rather than
the real source column; the converter accepts a same-line correction only when
the rendered text has one unique, contiguous source match. DOM range boundaries
also have directional affinity: a selection start between child nodes maps to
the following child, while its end maps to the preceding child.

## Flow of one keystroke

1. `beforeinput` in the page maps the target range to source offsets and reads
   the surrounding DOM text as context.
2. **In-place edits** (typing/deleting inside one stamped run) let the browser
   mutate the DOM, post the edit, and shift later `data-s` stamps by the length
   delta immediately — so a batched second command in the same turn already reads
   post-edit coordinates. No re-render. An end-of-turn watchdog requires every
   allowed `beforeinput` to receive its matching `input`; an orphaned event
   discards the queued edit and resyncs before another command can flush it.
3. **Structural edits** (anything crossing runs, Enter, style toggles, paste)
   `preventDefault()`, freeze the page, and post. The host splices the source and
   re-renders; the freeze is what stops a keystroke from mapping against a DOM
   that's about to change shape. Every early-out on the host side must thaw
   (`__mdUnfreeze`) or resync, or typing stays dead until the 2s `frozenTimeout`
   safety net fires.
4. `MarkdownEditSplicer.apply` verifies before splicing: the replaced text must
   match, and the before/after context must match. Verification failure means the
   page and source genuinely disagree → resync (full re-render). Never guess.

Host-driven source changes (typing in the raw half of split view) close the old
page's revision epoch and freeze it **when the update is scheduled**, before the
debounce/render. The old DOM must never remain editable while `parent.text`
already names newer source: an accepted old-page edit would publish a whole
stale-based string and overwrite the raw-pane change.

## Revisions

`currentRev` numbers the source; the page mirrors it in `stampRev` and every
message declares the revision its offsets address.

- Exact match → apply.
- Older than `reseedRev` → the DOM those offsets described is gone → **drop**.
- Any other mismatch → **resync**.

`bumpEpoch()` opens a new epoch whenever the DOM is about to be rebuilt. It must
happen **when the rebuild is scheduled, not when it lands**: a host-driven caret
restore (undo/redo) doesn't freeze the page, so a keystroke during the async
render would otherwise arrive at a matching revision and splice into the
pre-restore source — typing the undo straight back out.

## What is mapped

| Input | Route | Notes |
| --- | --- | --- |
| Typing, delete, forward/word delete | in-place | cross-run variants go structural |
| ⌘X | in-place / structural | falls back to the DOM selection when WebKit omits target ranges; whole styled runs/blocks consume their hidden Markdown syntax |
| Enter | structural | list items keep their **source** indentation (`listBreak`) |
| Enter in a table cell | caret move | last row asks the host to append a row |
| ⌘B / ⌘I / ⌘⇧X | structural | toggles off when already wrapped |
| Format → inline styles / Link | structural | shared source formatter; inline cross-run selections are blocked |
| Format → headings / quote / lists / rule | structural | expands to source line boundaries and supports multi-block selections |
| ⇧Enter | structural | writes a `\` break, and swallows the next line's leading whitespace |
| ⌘V | structural | host reads `NSPasteboard`; see below |
| IME / dead keys / predictive text | reconciled | whole run diffed at `compositionend` |
| Checkbox click | host callback | `onCheckboxToggle` |

**Not mapped** (blocked, no-ops): drag-and-drop text, list indent/outdent,
formatting a cross-run selection that intersects hidden inline Markdown syntax,
selections spanning table cells (their source interval owns pipe delimiters),
selections whose endpoint touches a declared read-only island,
non-verbatim inline code (for example a code span whose newlines were folded),
anything else. A blocked input must leave the source untouched and the page
usable — `EditBridgeUnmappedInputTests` and `EditBridgeMixedSelectionTests`
enforce exactly that.

### Selection handoff

The styled and raw editors can report an exact UTF-16 source range, including a
zero-length insertion point, through `onSourceSelectionChanged`. This is
separate from `onSelectionChanged`, whose nil-for-caret contract exists for
split-pane highlight mirroring. `MarkdownSelectionTarget` installs the captured
range in a newly mounted editor and is token-gated so repeated switches to the
same range still apply. The styled page publishes once more on blur, bypassing
the normal selection debounce, so clicking the mode picker cannot lose the most
recent caret or selection. Unmappable rendered positions report nil rather than
carrying a stale or guessed range into raw mode.

### Paste

The page posts `op: 'paste'` with its range only; the **host** fills in the text
from `NSPasteboard`. WebKit sanitizes the plain-text flavor of a paste's
`dataTransfer` — a multi-line paste reaches the page with its newlines already
stripped — so the pasteboard is the only faithful source. Plain text only:
markdown *is* the rich form. Inside a table cell newlines fold to spaces.

## Rendering side

- Blocks render as **fragments**; a fragment's `signature` normalizes stamps
  relative to its first, so a pure offset shift doesn't make later blocks look
  changed. `MarkdownBlockDiff` turns two fragment lists into a contiguous block
  replacement the page applies with `__mdPatchBlocks` — no navigation, no flash.
- The page computes the tail's stamp delta from its **own live stamps**, because
  fast-path typing shifts stamps without re-rendering, leaving the host's
  fragment baseline stale.
- A patch the live DOM doesn't recognize returns `false` and falls back to a full
  swap, so a mis-patch is impossible by construction.
- Patch/full-swap callbacks are generation- and revision-gated, and the fragment
  baseline advances only after WebKit acknowledges the DOM transaction. A late
  callback can never overwrite newer HTML or make future diffs target a page
  that never accepted their baseline.
- Documents are untrusted input: `HTMLPassthroughSanitizer` strips script,
  framing and remote-loading HTML from the one seam (`.htmlBlock`) where a
  document's own markup reaches the page. The page hosts the edit bridge, so
  script there would have the document, the network and the clipboard in reach.

## Test seams, cheapest first

1. `MarkdownEditSplicerTests` / `…EdgeTests` — pure splice/verify logic.
2. `MarkdownBlockFragmentTests`, `MarkdownBlockDiffTests` — patch computation.
3. `CoordinatorBridgeHarness` — the **real** coordinator against a live
   `WKWebView`, with only the SwiftUI round-trip emulated. This is where WebKit's
   actual behavior gets pinned down; prefer it over reasoning about WebKit.
4. `EditBridgeFuzzTests` — random edit scripts, asserting DOM/source convergence.

A healthy session records **zero** resyncs, dropped edits and hard rejections;
the suites assert those counters, so a regression that still "works" but churns
shows up as a failure.

Selected deletion (Cut, Backspace, or Forward Delete) carries `syntaxStart`,
`syntaxEnd`, and `blockPrefixes` only when the DOM selection owns the complete
visible boundary of those elements. The splicer then verifies and consumes the
adjacent source delimiters. This keeps deleting `**text**`, `[text](url)`, a
heading, or a list item from leaving empty or unbalanced syntax. Boundary
metadata that does not match the source is vetoed; it is never used as
permission to guess. Nested rendered traits may expose a different DOM ancestry
order than their authored delimiters; the splicer therefore verifies the exact
declared delimiter set against the source boundary without relying on tag order.
