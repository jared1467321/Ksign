Run `bash Tests/InstallDiagnostics/run.sh` on macOS with Swift tools. Exercises
production disk writing, JSON escaping, serialized concurrent writes, rotation,
preservation across launch IDs, and safe failure when the destination is invalid.
Also run `bash Tests/BackgroundTaskRecovery/run.sh` and build the iOS app in Xcode.

On device, ASign's Documents/Diagnostics folder contains diagnostics.jsonl and
one rotated diagnostics-previous.jsonl (about 2 MB each). Share both files after
reproducing the failure. Each JSON line has a UTC timestamp and process run ID.
Payload completion describes one HTTP response, which may be only a range; it
does not prove the whole IPA was received or that installation succeeded.

The logger samples process footprint and advisory available memory every five
seconds while installs are active. Lifecycle events, memory warnings, install
statuses, group sizes, payload sizes/ranges and background-task expiration are
queued without waiting for disk I/O, then flushed by a utility worker. At most
64 events are pending, with bounded strings; excess events are dropped and a
later record reports the drop count. Logs include bundle IDs and
error descriptions; inspect them before sharing publicly. They do not copy IPA
contents, certificates or pairing files. Logging does not depend on stdout capture.

Test foreground/background transitions, a large fully local batch, pause/retry/
cancel, and relaunch. Confirm prior records remain after relaunch, sampling stops
when installs settle, and a normal batch records its terminal state. Failure to
write (disk full or protected data inaccessible) is ignored and retried on the
next event. No crash handler is installed: sudden kills can lose queued records and the latest
sample, and absence of a termination callback does not establish a crash or kill
reason. This is evidence collection, not an authoritative crash report.
