# SDCopy — Known Gaps and Open Questions

A forward-looking inventory of places where a clone-style backup using
SDCopy may fail, drift, or silently produce a destination that doesn't
faithfully mirror the source. Maintained by reading what we *have* and
asking what we *don't*. New gaps should be appended at the appropriate
priority and category; resolved gaps move to PROGRESS.md.

The bias is toward **data fidelity**, not feature completeness. A
clone-style backup is only valuable to the user if the destination is a
trustworthy mirror — every gap below is framed against that test.

This document explicitly assumes a **data clone** (user-data volumes,
non-bootable) as the primary use case. Bootability gaps are listed at
the end as out-of-scope unless that scope changes.

---

## Priority legend

| Pri | Meaning |
|-----|---------|
| **P0** | Silent wrong copy / data loss. The dst diverges from src and nothing in the run flags it. Blocker for correctness. |
| **P1** | Operations fail or skip when they should succeed. Backup is incomplete; user sees errors or has to retry. |
| **P2** | Suboptimal but functional. Performance, log clarity, or ergonomic concerns. |
| **P3** | Niche configuration, observability nice-to-have, or low real-world incidence. |

## Status legend

| Status | Meaning |
|--------|---------|
| **Open** | Known, not started. |
| **Mitigated** | Partial fix landed; the remaining gap is documented and bounded. |
| **Verify** | Speculative — needs investigation to confirm it's a real gap before scoping a fix. |

---

## A. Correctness — data fidelity (P0 priorities live here)

### A0. Self-copy / self-target safety — **P0, Done (2026-05-13)**
Three failure modes that all silently corrupt a backup were unguarded:
src == dst (any spelling, including double-mounts and APFS
firmlinks); dst inside src (recursive copy of in-progress backup);
src inside dst (with `--delete`, wipes every dst sibling of src).
Added `validate_src_dst_paths` early in `sdcopy_run`: `stat()`-based
(dev, ino) identity check + `realpath` + `/`-boundary prefix overlap
in both directions.  Hard abort with explicit stderr message; no
escape hatch.  Pinned by `testSelfCopy_Refuses{SrcEqualsDst,
DstInsideSrc, SrcInsideDst}`.

Known edge case (not fixed): a deliberately-constructed firmlink
ancestor pair like (`/Users/me`, `/System/Volumes/Data/Users/me/sub`)
slips through the prefix check because `realpath` doesn't normalize
firmlinks.  Same-physical-entry catch still works (the dev+ino test
fires for that case if both paths point at the same inode).  Real-
world incidence is near zero — users construct
`/System/Volumes/Data` paths by hand very rarely.

### A1. Symlink-target retarget without an mtime change — **P0, Done (2026-05-13)**
Added `DIFF_SYMLINK_TARGET` (1 << 13) and a `readlink`-compare in
`compare_entry` that fires for VLNK entries after the mtime check
passes. Routed through the existing UPDATE path so the executor's
`fs_copy_symlink` re-creates the link with the new target. Two
`readlink` syscalls per same-mtime symlink; non-symlinks pay nothing.
Pinned by `testSymlinkRetarget_DetectedViaReadlink_WhenMtimePreserved`.

### A2. xattr name + value cross-FS normalization — **P1, Open**
Filename normalization (HFS+↔APFS) was just fixed in
`parse_bulk_record`; xattr comparison still uses raw `strcmp`/`memcmp`.
Names are reverse-DNS ASCII in practice and very low risk. Values are
two distinct sub-gaps: (a) text-bearing xattrs like
`com.apple.metadata:kMDItemFinderComment` can normalize-drift across
volumes — real but uncommon; (b) bplist-wrapping xattrs like
`_kMDItemUserTags` have container-byte differences even when the
contained strings are canonically equal — cannot be fixed by blanket
normalization; needs a typed comparator per xattr name. See
`[[project-xattr-normalization-gap]]` memory.
*Fix shape:* whitelisted text-value normalization is straightforward;
bplist-aware comparison is a separate design.

### A3. Hardlink graph completeness when same inode appears in disjoint subtrees — **P1, Verify**
The hardlink_map keyed by inode catches re-encountered hardlinks within
a run. If a hardlink graph spans subtrees that the FTS walk visits in
an order where the *second* member is encountered before the *first*'s
post-order publish, behavior is unclear without re-reading the code.
*Action:* re-read `HardlinkMap.swift` and the executor's link emission
to confirm ordering safety, especially with dirty-set pruning that may
visit only half of a graph in incremental runs.

### A4. Resource fork roundtrip on cross-volume + UPDATE-META path — **P1, Verify**
`copy_via_handrolled` uses `copy_xattrs_fd` which preserves
`com.apple.ResourceFork` (it's just a xattr). But the UPDATE-META path
goes through `fs_update_metadata` / `sync_xattrs_path` — confirm that
resource forks survive an UPDATE-META that fires on a file with a
content-equal but metadata-different sibling.
*Action:* targeted test in `FsOpsMetadataTests`.

### A5. UF_COMPRESSED loss on hardlinked-dst in-place update — **P2, Mitigated (documented)**
`fs_update_regular` falls through to `update_inplace_handrolled` when
dst has multiple hard links; that path does not preserve
UF_COMPRESSED. Comment at fs_ops.c:1068-1077 acknowledges this as an
intentional trade-off: hard-linked compressed files are rare; keeping
the inode coherent across the link graph beats compression
preservation on this edge.
*No action needed unless a real-world report surfaces.*

### A6. CoreSpotlight Cache subtree-copy excludes — **P1, Mitigated**
Subtree-copy bypasses volume-root-anchored built-in excludes; a 882s
metadata-bound run was observed on CoreSpotlight Cache only because of
this. See `[[project-pathtest-sizecheck-run]]` memory; follow-up is
#85 territory.
*Fix shape:* make built-in excludes match against the path-as-it-would-
appear-at-volume-root regardless of the scanner's entry point.

### A7. Smart-update "same mtime, different content" — **P3, Open**
The engine trusts mtime/size as a proxy for content equality (the
standard smart-update bet). A file rewritten in place with size and
mtime preserved (`utimensat` after write) is undetected. This is the
documented contract of incremental backup; flagged here only as
context for users who need stronger guarantees.
*Fix shape:* opt-in `--verify` mode that hashes both sides. Substantial
perf cost, only some users want it.

### A8. Birth time (st_birthtime) preservation — **P3, Verify**
APFS records `st_birthtime` and Finder surfaces it. `copyfile` and
`utimensat` paths don't restore birthtime explicitly — confirm
whether `copyfile(COPYFILE_ALL)` preserves it on the cross-volume
path and whether the hand-rolled path does not.

---

## B. Robustness — operations that should succeed and don't

### B1. ENOSPC during atomic temp+rename copy — **P1, Done (2026-05-13)**
Implemented self-borrow in `try_smart_delete_recovery`: when the
orphan walk recovers less than `op->size` for an UPDATE, the
recovery path unlinks the existing dst (which was about to be
overwritten) so the retry takes the COPY path on a now-roomier
disk. See sdcopy.c:3260 and the E2E test
`testEnospcRecovery_BorrowsFromDstBeingUpdated`.

Companion fix in the same function: `target` for `OP_WOULD_UPDATE_META`
is now `SLACK_BYTES` (100 MiB) instead of `op->size + SLACK_BYTES`.
A metadata-only update (xattr / ACL / mode / flags) writes KB-scale
bytes; targeting op->size for a multi-GB file meant smart_delete
walked the full dst, fell into its 30-second wait deadline, then
returned whatever was actually freed. The retry still usually
succeeded (the caller gates on `recovered > 0`, not `>= target`)
but every UPDATE_META ENOSPC paid a 30-second tax it didn't need.

### B2. Multi-op ENOSPC cascade — **P2, Open**
Each op gets a single retry after smart_delete. If a long sequence of
near-full UPDATE ops keeps hitting ENOSPC, each pays a full
smart_delete pass and a borrow. Hot path is still correct; just slow.
*Fix shape:* track recent recovery outcomes and short-circuit
follow-on retries when the dst is clearly oversubscribed (better to
fail fast with a clear "the dst is too small" diagnostic than to
death-march through every file).

### B3. Long-path coverage (paths > PATH_MAX) — **P1, Mitigated**
`fs_*_long` variants exist for the immediate fs_ops paths. The unified
op_t-allocated-string work is tracked in `[[project-75-38-unified]]`
memory. Until that lands, long-path correctness depends on every code
path consistently routing through the `_long` variants — easy to
miss when adding new ops.
*Action:* finish #75/#38 unification.

### B4. dst becoming read-only mid-run — **P2, Verify**
EROFS handling: when a volume is remounted read-only or runs out of
inode space, errors should produce a clear abort, not death-by-EPERM.
Confirm by examining `errno_is_ignored` for these errnos.

### B5. Live-src ENOENT race — **P1, Mitigated**
Tiered classification landed in #87; flag is `[[feedback-enoent-src-semantics]]`.

### B6. Power loss / hard crash mid-write — **P1, Mitigated**
Temp+rename atomic pattern means a power loss leaves either the old
file intact or the new file in place — never a half-written
destination. The B1 borrow path forfeits this guarantee for the
specific file being updated when the disk is full enough that the
atomic pattern can't complete. Documented; tradeoff is explicit.

### B7. State file corruption recovery — **P2, Verify**
`BackupState` is `Codable` JSON written via temp+rename. Corrupt
JSON on read: confirm we fall back to a full scan rather than crash.
Empty file: same. Malformed UUIDs: same. These are all rare but each
should fail loud and force a full scan.

---

## C. Performance

### C1. HDD deep b-tree slowdown on long-lived backup trees — **P2, Mitigated (FS limitation)**
Documented in `[[project-hdd-deep-btree-diagnosis]]` memory. Not a code
bug; HFS+/older-APFS b-tree seek ceiling on cold subtrees. Mitigation
is reducing per-file seek count, not avoiding the disk.

### C2. Mail-attachment-style very-wide directories — **P2, Open**
`dst_bulk_index_t` is a sorted array with binary-search lookup;
O(log n) is fine asymptotically but the constant factor on directories
with >100k entries shows up. A hash-table dst index would be a
modest constant-factor win — only worth it if real workloads
demonstrate the lookup phase dominating.

### C3. xattr / ACL prefetch on HDD — **P3, Mitigated**
The dst-side xattr prefetcher exists; ACL prefetch does not (ACL is
already inline via getattrlistbulk). HDD xattr cost dominates only on
deep `--xattr-mode strict` runs; cheap/lenient bypass it.

### C4. ExFAT 2-second mtime resolution — **P2, Verify**
ExFAT timestamps round to 2 seconds. APFS is nanosecond-resolution.
Every cross-volume run targeting an ExFAT dst would round-trip src's
mtime through ExFAT precision, and on the NEXT run the src vs dst
mtimes wouldn't compare equal — causing every file to look UPDATED
forever. The fix is to round both sides to dst's precision before
compare. Confirm: does the engine already mtime-tolerance-compare,
or is this a real "every run re-copies everything to ExFAT" bug?

---

## D. Verification & integrity

### D1. Read-back verification (opt-in) — **P2, Open**
No current mode hashes dst after write and compares against src.
Common request for archive-grade backups. Adding it as an opt-in flag
(`--verify`) is a clean feature: read dst back through a non-cached
fd, hash, compare to a cached src hash. Cost: ~2× I/O on the
verified files.

### D2. Long-term bit-rot detection on dst — **P3, Open**
A separate scrub mode that periodically re-hashes dst and reports
divergence. Outside SDCopy's normal flow; could be a sibling tool.

### D3. Smart-update content-trust audit — **P3, Open**
Periodic `--full-content-verify` mode that ignores mtime/size
short-circuits and reads both files. Same shape as D1 but applied to
every file, not just newly-written ones. For users who don't trust
mtime as a proxy for content.

---

## E. Recovery & observability

### E1. Crash-resume — **P2, Verify**
A run that's killed mid-operation: on restart, are the partial temp
files (`.snapcopy.<pid>`) cleaned up? The scanner skips them on
enumeration (strstr ".snapcopy."), but they sit on disk until something
explicitly removes them. Confirm: is there a startup sweep, or do
they accumulate? If they accumulate, a long-running periodic backup
quietly wastes disk.

### E2. State UUID change detection — **P2, Mitigated**
TODO.md:item-12 (state-file fix) notes the recommendation to persist
`FSEventsCopyUUIDForDevice` so erasures/purges force a full scan.
Currently deferred.

### E3. Profile-run observability backlog — **P3, Mitigated**
`[[project-followups-runtime-observability]]` lists the two deferred
ideas (log exit reason, caffeinate-wrap profile.sh).

### E4. Stale "poc:" log prefixes — **P3, Open**
Two residual `\npoc:` log prefixes remain after the SDCopy rename:
`sdcopy.c:1719` (abort message) and `sdcopy.c:3275` (ENOSPC banner).
Trivial cosmetic fix; intentionally not bundled with the ENOSPC borrow
change to keep diffs surgical.

---

## F. Edge cases — filesystem corners

### F1. APFS clone-relationship preservation across volumes — **P2, Verify**
Two src files cloned from each other (`copyfile -c`) share extents on
APFS. When backed up across volumes via `copy_via_handrolled`, dst
gets two independent full-size copies (the clone relationship is
local to APFS, can't survive cross-FS). Same-volume backups via
`copy_via_clonefile` preserve the relationship for `src↔dst` but not
necessarily `src1↔src2 → dst1↔dst2`. Worth confirming what users
expect here and documenting either way.

### F2. Quarantine / provenance xattr ergonomics — **P3, Mitigated**
`com.apple.provenance` is kernel-added and excluded from compare
(verified in TODO.md item). `com.apple.quarantine` is preserved
normally. Behavior is consistent.

### F3. Sparse-bundle DMG as dst — **P3, Verify**
Sparse bundles auto-grow but have band-file overhead. Behavior should
match a regular volume but ENOSPC semantics differ (the bundle can be
on a volume that itself runs out). Confirm smart_delete + borrow path
handle this; the layer-of-indirection ENOSPC could surface as a write
error rather than the inner DMG's ENOSPC.

### F4. Synthetic FS entries (/dev, /proc-like) — **P3, Verify**
Built-in excludes should cover these but the volume-root-anchored
issue (A6/#85) means subtree-copy could traverse them. Audit
built-in excludes for `/dev`, `/.vol`, `/Volumes` self-references.

---

## G. Cross-filesystem specifics

### G1. SMB / AFP / NFS network shares as dst — **P3, Verify**
Many semantics differ: no clonefile, no fcntl(F_NOCACHE) honored
necessarily, different xattr semantics (some servers strip xattrs),
ACL representation differs. Not a stated use case; if users do it,
behavior is best-effort.

### G2. USB bridge FAT-limit enforcement — **P3, Mitigated**
ENAMETOOLONG diagnostic at sdcopy.c:3422 flags this case for users.
Documented; no automatic fix.

### G3. FileVault / encrypted-disk-image read access — **P3, Verify**
src side: encrypted volumes must be unlocked before sdcopy runs; this
is a user-environment concern, not a code one. Confirm there's no
path where we'd attempt to read past an encrypted boundary and get a
silent failure rather than a clear error.

### G4. Case-sensitivity mismatch (case-sensitive src → case-insensitive dst) — **P1, Verify**
`foo.txt` and `FOO.txt` are distinct on case-sensitive APFS; on
case-insensitive dst, the second copy overwrites the first. The
engine doesn't currently detect this collision class. Worth a clear
abort or a documented warning.

---

## Out of scope

These are deliberately *not* on the list:

- **Bootable system clone (sealed system volume)**: Apple has
  effectively locked this down from Big Sur onward. `asr` / ASIF is
  the only path, and it's not SDCopy's problem.
- **Firmlinks between system and data volumes**: same scope as
  bootable; data-only clones don't traverse firmlinks.
- **Time Machine catalog compatibility**: SDCopy is not a Time
  Machine backend.
- **Cryptographic verification of dst against src** beyond a simple
  hash (Merkle trees, signature chains, etc.): archival/forensic
  features, separate tool.

---

## How to use this document

When picking up work, scan P0 first — those are the items that can
silently corrupt a backup and need to fail loud before they're left to
ride. P1 items are the next tier and represent real user-facing
failures.

Items marked **Verify** are working hypotheses that still need a code
read or a targeted test before a fix is scoped. Don't commit a fix to
a Verify gap without first writing the verifying test.

Items marked **Mitigated** have a partial fix or a deliberate scope
limit — re-read the linked memory or follow-up before changing the
behavior, because the limit was usually chosen on purpose.
