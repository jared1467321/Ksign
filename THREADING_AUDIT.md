# Main-thread audit — November 5, 2026

This pass follows UI entry points into filesystem access, native parsing,
database operations, network callbacks, server lifecycle, and progress delivery.
It supplements the earlier download, archive, signing, install-progress, log,
temporary-file, and aurora worker changes. It is a source audit with Linux
regression checks, not an on-device frame-time measurement.

## Changes

| Path | Work moved off main | Result delivery / ownership |
| --- | --- | --- |
| App Store catalog | Filtering, sorting and section grouping, including initial/default ordering | Bounded worker mailbox; generation check drops obsolete results. The table keeps one complete snapshot until its replacement is ready. Empty results remain cached. |
| Source import | Subscription-code decoding, duplicate checks and batch database saves | URL/repository values cross tasks. A serialized private context saves records and merges permanent IDs into the view context. Fetched `AltSource` objects stay on main. |
| Local installation server | Vapor/TLS setup, hostname file reads, port retries, server start and shutdown | A serial lifecycle worker; async startup finishes before the prompt opens. Cancellation and epoch checks suppress obsolete prompts. Endpoint getters use a cached host. Shared server state uses short locks. Constructors perform no server startup. |
| Certificates | Profile lookup, embedded-data faults and decoding; password validation; default-certificate scanning; directory deletion and imported-record save | Profile reads use private Core Data contexts and UI tasks reject cancelled results. Import completion follows the actual database save. |
| Backup / restore | Certificate/source fetches, certificate-file reads/writes, validation, matching and bulk saves | Private contexts retain their own managed objects. A failed restore rolls back its worker transaction and staging directories. Preferences and appearance apply on main after success. |
| Bulk export | Archive lookup, directory creation, IPA cloning/copy fallback and final moves | Immutable app snapshots enter the detached task; only finished URLs and progress return to the UI. Failed staging is cleaned up. |
| Editors and signing artwork | UTF-8 reads, encoding and atomic writes; selected image loading/resizing; entitlement file staging/deletion | UI state changes on main. Save completion compares against the saved text, preserving edits typed during the write. |
| Library inspection / signing preflight | Legacy Mach-O dylib inspection, app-directory scans and signing-review installed-app lookups | App metadata is copied before dispatch. Native parsing and scans execute on workers. |
| Report export / cleanup | Reading and rewriting report CSS, regex replacement, temporary report/backup/dylib removal | Theme values are captured on main before worker file access. Export uses the exact prepared report URL. |
| Reset actions | Cache-size inspection, recursive deletion, cache clearing, database counts and batch deletion | Reset waits for worker completion before reopening the app; the UI disables repeat actions while resetting. |

## Main-thread work retained

SwiftUI/UIKit rendering, view configuration, presentation, observable state,
appearance changes and view-context managed objects remain on main. Small
in-memory filtering of fetched library rows also remains with those objects.
Moving managed objects into detached tasks would violate Core Data confinement.

The view context still saves small UI edits. Backup/restore flush pending UI
edits before opening a private-context transaction. Initial persistent-store
loading, image-pipeline configuration, creation of the fixed launch directories,
and copying the three small bundled server identity files remain synchronous
bootstrap work. These are explicit profiling targets if cold launch still stalls;
this audit does not claim they have zero I/O cost. Bulk certificate scans and
temporary-directory cleanup run off main.

Moving computation off main also does not eliminate the cost of SwiftUI layout,
table reloads, Core Data merges, GPU rendering or memory pressure. Those need
measurements with realistic libraries and source catalogs.

## Validation

Run `python3 .github/scripts/check_ui_workers.py` with the local Swift toolchain,
or pass `--swiftc /path/to/swiftc`. The script starts a loopback HTTP server.

The checks compile and exercise production transfer/mailbox/file-worker code,
the real repository decoder and catalog projection, and the production server
lifecycle. They cover concurrent transfers, pause/resume, cancellation, retries,
rejected HTTP ranges, background completion, UI snapshot merging, exact aurora
ink bytes, a 10,000-row catalog, idempotent server start, ordered restart, failed
port cleanup and cancellation during startup. Transfer, catalog and server tests
deliberately block the main thread.

The Linux server tests substitute the unavailable Vapor listener and route
registration; they test lifecycle scheduling and cleanup, not actual TLS or iOS
installation. Linux substitutes platform imports for the other harnesses too.
All changed Swift files additionally pass Swift frontend syntax parsing.

An Xcode iOS build remains required to type-check UIKit/Core Data integration.
On a device, use Instruments Hangs and Time Profiler while scrolling/searching
a large catalog, exporting a large IPA, opening certificates and editors,
backing up/restoring certificates, and starting/cancelling/retrying server
installs. Enable Core Data concurrency debugging and check main-thread traces
for filesystem, crypto, archive/Mach-O and server lifecycle stacks. Compare cold
launch separately from steady-state interaction.
