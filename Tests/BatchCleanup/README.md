Run `bash Tests/BatchCleanup/run.sh` on Linux with clang++ and OpenSSL headers.
The test builds the production Mach-O parser and file mapper and checks actual
VM mappings across explicit cleanup, repeated cleanup, reopening, destruction,
and failed initialization. Unused signing functions are discarded at link time;
this is a mapping-lifetime regression, not an end-to-end signing test.

On an iPhone:

- Download a large Vault batch with the Downloads tab visible through the last
  completion. Repeat with existing downloaded files, with the Vault sheet
  minimized, and after backgrounding/returning near the end. Check that rows
  remain stable and the Downloading section disappears without a crash.
- Import completed downloads immediately, then import a batch using each
  extraction backend. Verify the source IPAs remain available and all apps
  appear in the library.
- Sign a batch, including tweak injection/removal, and repeat in the same app
  session. Check successful installation and use Instruments VM tracking to
  confirm Mach-O mappings do not accumulate after operations finish.

The supplied crash report shows a main-thread UICollectionView batch-update
assertion (SIGABRT). Host tests cannot reproduce or validate SwiftUI/UIKit list
transactions; the download completion regression requires the device checks.
