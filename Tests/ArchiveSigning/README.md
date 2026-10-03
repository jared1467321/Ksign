# Archive-backed signing regression

The checkout was fast-forwarded to `7724ddc` on
`Color-picking-and-theme-improvement`. Analysis compared it with the pre-archive
baseline `19dcd5f` and archive introduction `77a86d1`.

## First concrete bug: raw compressed bytes labeled STORE

`SigningHandler.move()` calls `ASignArchive.rebuildWithOverlay(compression: .none)`.
`asign_archive_rebuild_with_overlay()` configures the writer with compression
level zero, then calls `mz_zip_writer_copy_from_reader()` for untouched members.

In SideStore/minizip-ng, `mz_zip_writer_copy_from_reader()` sets raw mode but
passes the writer's compression level to `mz_zip_entry_write_open()`. The latter
unconditionally sets `compression_method = STORE` when the level is zero,
including raw writes. Thus a source DEFLATE payload is copied without inflation
but declared to be STORE. zsign hashes the decoded source resource; a consumer
of the final IPA instead sees compressed bytes under a STORE header.

Reproduction before the fix: a 19,000-byte resource compressed to 82 bytes,
native rebuild return status **0**, output method **0 (STORE)**, and Python's
independent ZIP reader reports **Bad CRC-32**. This needs neither an unusual IPA
nor duplicates. Any untouched DEFLATE member can trigger it.

The fix temporarily sets a nonzero/default compression level for raw copying,
then restores the requested level for overlay files. Original methods and
compressed payloads are retained. Overlay files can still be stored.

The pre-archive path signs a complete filesystem app and creates an IPA from
decoded disk files. STORE accurately describes those bytes; it never takes this
new raw-copy route. The archive-backed architecture itself remains viable.

## Other reproduced correctness issues

- **Duplicate members:** `AddArchiveFileIndex()` hashes the last duplicate, but
  the old rebuild copied every untouched duplicate. Different readers can then
  select a different payload. Sparse materialization also selected duplicates
  independently: an early Mach-O followed by an ordinary resource left the early
  binary in the overlay. Both materialization and rebuild now first index central
  directory positions and use only the last entry for each exact name. The index
  sorts once and uses binary searches; it does not decompress resources.
- **Executable mode after signature growth:** `ZMachO::ReallocCodeSignSpace()`
  replaces the original inode with a temporary file. A native signing fixture
  changed mode from `0755` to `0664`, which the rebuild correctly but undesirably
  serialized. Preserve the original mode on both thin and fat replacement files.
  This bug also exists in `19dcd5f`; it is not the archive redesign's root cause.
- **CRC suppression:** `7724ddc` accepted `MZ_CRC_ERROR` from reads/extraction
  without independent proof that the decoded bytes were valid. A deliberately
  corrupted stored payload was accepted. Restore strict CRC handling. Obtaining
  the full expected byte count cannot distinguish corrupted bytes from stale
  checksum metadata. No general stale-CRC compatibility workaround is claimed.

## Pipeline audit

| Area | Evidence / conclusion |
| --- | --- |
| Coordinator and bridge | Bulk coordinator and `FR.signPackageFile` use detached tasks. The Swift wrappers pass archive path, root and deletion list through `ZsignBridge` to `SetArchiveBacking`; force signing is enabled. |
| Logical index | Disk paths take precedence; virtual archive resources use central-directory positions. Exact-name duplicate selection now matches materialization and output. |
| Overlay paths | `SigningHandler` retains the original `Payload/<name>.app` root. Rebuild joins app-relative paths to the sparse workspace and appends new members under that same root. Tests verify nested paths and replacements. |
| Nested bundles | Native signing fixtures include framework, appex and Watch app bundles, without explicit ZIP directory entries. Nested objects sign before parents; parent seals cover generated nested signatures and modified binaries. |
| Symlinks | Sparse materialization selects symlinks; `GetLogicalSymbolicLinkTarget()` prefers `readlink()` on the overlay. The explicit symlink writer stores its target as the ZIP payload with POSIX symlink attributes. The fixture verifies the final target against the seal. |
| CodeResources | Original signature members are excluded from the archive index and skipped during rebuild. The append pass includes newly generated overlay signatures at every tested bundle depth. |
| Mach-O selection | The materializer probes every authoritative non-directory member with at least four bytes. It recognizes all six magic values recognized by zsign's object discovery (and FAT64 values too). The sparse fixture verifies resources stay virtual and actual signed Mach-O bytes replace source members. FAT64 support in the zsign parser is not added by this patch. |
| Attributes | Valid POSIX modes are restored by minizip extraction and serialized by the writer. Signature-space reallocation needed the additional mode-preservation fix. Raw copies preserve source attributes. |
| Resource bytes | zsign hashes archive members with uncompressed reads. Tests independently hash final IPA members and compare every generated `files2` digest/target. CodeDirectory special slots are also checked against final Info.plist and CodeResources bytes. |
| Raw rebuild | Tests check method, compressed payload, decoded bytes and attributes for untouched STORE/DEFLATE members, with output levels zero and six. Successful native return codes alone are insufficient. |
| CRC | Corrupt entry materialization and direct reads now return `-105`. Raw copying preserves source metadata and does not prove source integrity; normal resource hashing remains strict. |
| Performance | `AddArchiveFileIndex()` repeatedly uses `std::find` over growing file/folder vectors, giving quadratic work. The rebuild's existing string set also uses linear searches. Resource hashing defaults to at most four workers, each with its own archive reader. Bulk processes apps sequentially. These are performance leads, not proof of the observed UI freeze. No scheduling/UI changes or performance redesign are included. |

These checks cover the synthetic fixtures and source paths described above, not
all possible ZIP path aliases, contradictory file/directory layouts, platform
metadata or bundle shapes. Device OTA acceptance is not tested on this Linux
host; certificate/CMS validation is also outside the ad-hoc fixture.

## Run

Requires a C/C++ toolchain, Python 3, zlib and OpenSSL development libraries, and
an existing SideStore/minizip-ng checkout with its SwiftPM `include` directory:

```sh
python3 Tests/ArchiveSigning/run.py /path/to/minizip-ng
```

Validated against SideStore/minizip-ng develop revision
`12a8ab8ccac4a36d4a45340921c7de5f18b0efab`.

The runner compiles the actual CASignArchive and zsign core into a temporary
library/executable, builds tiny synthetic IPAs, runs sparse materialization,
performs real ad-hoc native signing using the repository's Mach-O fixture, and
reads the rebuilt archive with Python's independent ZIP/plist implementations.
It downloads nothing and leaves no build products in the repository.
