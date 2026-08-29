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

WebKit's paragraph selection ends at the following block's first visible
character. When that character has hidden opening syntax (for example `**`),
the page marks the boundary and the host verifies/snaps it to the source line
start, then trims the inter-block whitespace from the mirrored selection. This
keeps both the blank separator line and the next paragraph's Markdown opener
out of the raw-pane highlight.

Selection reports also include any inline delimiter owned by their visible
start or end boundary. Thus double-clicking all of `**word**`, or
triple-clicking a paragraph that starts with emphasized text, mirrors the
attached Markdown formatting characters into the source pane.

## Flow of one keystroke

1. `beforeinput` in the page maps the target range to source offsets and reads
   the surrounding DOM text as context.
2. **In-place edits** (typing/deleting inside one stable stamped run) let the browser
   mutate the DOM, post the edit, and shift later `data-s` stamps by the length
   delta immediately — so a batched second command in the same turn already reads
   post-edit coordinates. No re-render. An end-of-turn watchdog requires every
   allowed `beforeinput` to receive its matching `input`; an orphaned event
   discards the queued edit and resyncs before another command can flush it.
   Edits near visible Markdown delimiters, or whitespace edits at a hidden
   inline-syntax boundary, are excluded because they can change how the run
   parses even though they do not cross a DOM node.
3. **Structural edits** (anything crossing runs, syntax-sensitive single-run
   edits, Enter, style toggles, paste)
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
| Typing, delete, forward/word delete | in-place | cross-run and Markdown-syntax-sensitive variants go structural |
| Typing / Return in fenced code | in-place / structural | mapped only when the rendered code is one exact source slice; Return inserts one source newline and syntax highlighting is preserved after re-render |
| ⌘X | in-place / structural | falls back to the DOM selection when WebKit omits target ranges; whole styled runs/blocks consume their hidden Markdown syntax |
| Enter | structural | list items keep their **source** indentation (`listBreak`), and task items continue as a new unchecked task; at a visual block start, any verified hidden Markdown prefix and the caret move down with the text |
| Enter in a table cell | caret move | last row asks the host to append a row |
| ⌘B / ⌘I / ⌘⇧X | structural | toggles off when already wrapped |
| Format → inline styles / Link | structural | shared source formatter; inline cross-run selections are blocked |
| Format → headings / quote / lists / rule | structural | expands to source line boundaries and supports multi-block selections |
| Format → List → Add List Item | structural | invokes the same verified list-continuation route as Enter for the focused styled list |
| List add button / ⌘Return | structural | appends after the target list's final item and restores the caret in the new item; ⌘Return prefers the caret's list, then the first source-mapped list visible from the top |
| ⇧Enter | structural | writes a `\` break, and swallows the next line's leading whitespace |
| ⌘V | structural | host reads `NSPasteboard`; see below |
| IME / dead keys / predictive text | reconciled | whole run diffed at `compositionend` |
| Checkbox click | host callback | `onCheckboxToggle` |

**Not mapped** (blocked, no-ops): drag-and-drop text, list indent/outdent,
formatting a cross-run selection that intersects hidden inline Markdown syntax,
selections spanning table cells (their source interval owns pipe delimiters),
selections whose endpoint touches a declared read-only island (including code
blocks whose rendered content cannot be proven to be a verbatim source slice),
non-verbatim inline code (for example a code span whose newlines were folded),
anything else. A blocked input must leave the source untouched and the page
usable — `EditBridgeUnmappedInputTests` and `EditBridgeMixedSelectionTests`
enforce exactly that.

At a block boundary, Backspace/Forward Delete may end at a visible run whose
opening Markdown syntax is hidden. The page flags that boundary and the host
snaps the deletion back to the verified source-line start, so the separator is
removed while an opener such as `**` remains intact.

Markdown rendering normally collapses repeated blank source lines. After Return
at a visual block start, the page installs a temporary stamped blank row before
the moved block so the edit is visible while the caret remains with that block.

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

Undo/redo caret restores include their physical source-line bounds. A caret in
hidden inline syntax (such as the opening `**` of a restored paragraph) snaps
to the nearest rendered run on that line; only a truly empty source line gets a
synthetic empty paragraph as its caret home.

### Paste

The page posts `op: 'paste'` with its range only; the **host** fills in the text
from the system pasteboard. WebKit sanitizes the plain-text flavor of a paste's
`dataTransfer` — a multi-line paste reaches the page with its newlines already
stripped — so the pasteboard is the only faithful source. A Cut keeps WebKit's
rendered plain-text flavor for other applications and adds a private exact
Markdown-source flavor; another Marker editor prefers that flavor, preserving
hidden syntax and block separators. External plain text remains the fallback.
Inside a table cell newlines fold to spaces either way.

## iOS

The bridge is one implementation; the two platforms differ in what WebKit does
underneath it, not in what the page asks for.

- **WebKit rebalances whitespace on iOS.** Delete a selection that leaves a
  space touching a space and iOS collapses the run to one, while the source
  keeps both. That breaks the invariant silently: every later offset in the run
  is short by the difference, and the *next* keystroke lands in the wrong place
  rather than the delete looking wrong. The `input` drain therefore checks each
  run against what the edit said it would hold, and when they disagree the edits
  still go out — they describe what the user asked for — followed by a resync
  that rebuilds the DOM from the spliced source. The resync carries the caret,
  because the edit knows where it belongs and the rebuilt DOM does not.
- The check is held to the same standard as the invariant itself: a run may show
  **less** than the source from its stamp (typing into an empty fenced block
  consumes the blank line's newline), but never something else and never more.
- **Text substitution** — autocorrect, predictive text, dictation — reaches the
  page two ways, and they are covered to different depths.
  - *Autocorrect* arrives as `insertReplacementText` and is mapped like any
    other in-run edit, including the retroactive kind that rewrites a word
    already typed. It shares its branch with `insertText`, so the mapping is
    well covered; what isn't is the `dataTransfer` fallback the branch uses
    when `e.data` is null. A synthetic event can't drive it — unlike cut and
    paste, `insertReplacementText` has no live-selection fallback, because a
    real one always carries target ranges.
  - *Dictation and predictive text* arrive as a **composition**, reconciled by
    diffing the whole run at `compositionend`. `EditBridgeTextSubstitutionTests`
    covers that on both platforms: a commit into a run, a cancelled
    composition, a commit inside `**bold**` that must not disturb the markers,
    and one spanning two runs, which resyncs rather than guessing. Driving the
    composition events directly is faithful here precisely because the handler
    deliberately trusts nothing they carry — it re-reads the run.
  - Marker supplies that missing UIApplication host in
    `MarkerIOSUITests/SoftwareKeyboardUITests`. It taps visible software-keyboard
    keys (never `typeText` for the behavior under test) and proves Smart
    Punctuation's `--` → em-dash replacement reaches Markdown source. QuickType
    and double-space probes run too, and skip with an explicit reason on
    simulators whose prediction dictionary or WebKit shortcut is unavailable.
    The styled page explicitly enables autocorrect, sentence capitalization,
    and spellcheck so WebKit OS-default changes cannot silently remove these
    features; `EditBridgeTextSubstitutionTests` verifies those page traits.
  The **raw** editor turns substitution off wholesale because it edits markdown
  source, where a curled quote changes meaning; the styled view edits prose, so
  it leaves substitution on and relies on the mapping.
- **Responder-chain routes don't cross over**, and the tests no longer ask them
  to. `perform(NSSelectorFromString("paste:"))` is answered by AppKit; on iOS a
  library test bundle has no UIApplication, so the action never arrives — and
  for `deleteBackward:` it takes the web process down, which truncated whole
  runs. `CoordinatorBridgeHarness.clipboardCommand` and `.deleteBackward()`
  branch instead: macOS keeps the real action, iOS drives the same contract
  from the page. The two are not interchangeable, and which one to use depends
  on where the work happens — *paste* is host-driven, so a dispatched
  `beforeinput` is enough, while *cut* and *backspace* take the fast path and
  need WebKit to actually mutate the DOM, so they go through `execCommand`.
- **A test host cannot read its own clipboard on iOS.** Without a UIApplication
  the process can't own a pasteboard write, so `UIPasteboard.general.string`
  returns nil — not blocks — even for the string just written.
  `MarkdownPasteboard.substitute` stands in for tests; the app leaves it nil.
- **Find** is `NSTextFinder` on macOS and `UIFindInteraction` on iOS; the
  formatting bar above the keyboard exists only on iOS, where there is no
  Format menu.

## Rendering side

- Blocks render as **fragments**; a fragment's `signature` normalizes stamps
  relative to its first, so a pure offset shift doesn't make later blocks look
  changed. `MarkdownBlockDiff` turns two fragment lists into a contiguous block
  replacement the page applies with `__mdPatchBlocks` — no navigation, no flash.
- Structural page edits shift a wholly surviving tail by the edit's **exact
  UTF-16 source delta**. If the fragment diff's tail straddles the old edit
  boundary (because prior fast-path typing left the fragment baseline stale),
  the patch is refused before mutation and a full swap restamps it. Host-driven
  patches without an exact edit delta instead validate their first and last
  live anchors before applying a uniform shift.
- A patch the live DOM doesn't recognize returns `false` and falls back to a full
  swap, so a mis-patch is impossible by construction.
- Patch/full-swap callbacks are generation- and revision-gated, and the fragment
  baseline advances only after WebKit acknowledges the DOM transaction. A late
  callback can never overwrite newer HTML or make future diffs target a page
  that never accepted their baseline.
- A structural patch that preserves a live editable tail clears the
  `exactFragmentText` marker. Its fragments remain safe for the next
  boundary-checked structural patch, but a later host-driven update uses a full
  swap rather than assuming renderer-normalized whitespace exactly matches the
  live tail.
- Documents are untrusted input: `HTMLPassthroughSanitizer` strips script,
  framing, event handlers and network-capable attributes such as `ping` from
  the one seam (`.htmlBlock`) where a document's own markup reaches the page.
  The generated page also carries a CSP that blocks all remote subresources
  unless the host explicitly opts in. The page hosts the edit bridge, so script
  there would have the document, the network and the clipboard in reach.

## Test seams, cheapest first

1. `MarkdownEditSplicerTests` / `…EdgeTests` — pure splice/verify logic.
2. `MarkdownBlockFragmentTests`, `MarkdownBlockDiffTests` — patch computation.
3. `CoordinatorBridgeHarness` — the **real** coordinator against a live
   `WKWebView`, with only the SwiftUI round-trip emulated. This is where WebKit's
   actual behavior gets pinned down; prefer it over reasoning about WebKit.
4. `EditBridgeFuzzTests` — random edit scripts, asserting DOM/source convergence.

A healthy session records **zero** dropped edits and hard rejections. WebKit may
legitimately force a recovery resync after rebalancing whitespace around a
deletion, so fuzz coverage treats exact DOM/source convergence and honest stamps
as the contract instead of constraining that platform/version-dependent count.

Selected deletion (Cut, Backspace, or Forward Delete) carries `syntaxStart`,
`syntaxEnd`, and `blockPrefixes` only when the DOM selection owns the complete
visible boundary of those elements. The splicer then verifies and consumes the
adjacent source delimiters. This keeps deleting `**text**`, `[text](url)`, a
heading, or a list item from leaving empty or unbalanced syntax. Boundary
metadata that does not match the source is vetoed; it is never used as
permission to guess. Nested rendered traits may expose a different DOM ancestry
order than their authored delimiters; the splicer therefore verifies the exact
declared delimiter set against the source boundary without relying on tag order.
For a selected deletion the live DOM selection is authoritative: physical
Backspace may report a collapsed WebKit target range even while that selection
is extended. Element-boundary selections that own a stamped wrapper take the
structural route so WebKit cannot delete the `data-s` element out from under the
fast path. When AppKit/WebKit declines a physical Backspace or Forward Delete at
a `PRE`/`CODE` boundary (which otherwise produces the system beep), the page's
keydown handler posts the contained code selection directly through the same
verified structural deletion route. It does not invoke WebKit's native delete
command, whose internal undo state can stop dispatching after a host-level undo.
The `<code>` inside a fenced `<pre>` is excluded from inline-code delimiter
metadata: its fences are block syntax, not adjacent backticks, and selections
contained within the stamped code content edit only that content.
