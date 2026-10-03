Run `bash Tests/BackgroundTaskRecovery/run.sh` on macOS with Swift command-line
tools. The runner compiles the actual manager with scheduler/UIKit/audio test
doubles; it does not submit real system tasks or change production imports.

Coverage:

- Expiration and foreground recovery for every workflow owner.
- Foreground replacement when a stale non-nil task reference survives.
- Preservation of progress, filename, worker counts and real failure results.
- Late expiration/launch callbacks, duplicate completion and stale progress.
- Queued requests that never launched and submission failures.
- An overlapping worker surviving a late finish attempt.
- Regular downloads continuing after expiration and finishing successfully.
- Finished batches staying finished after foreground recovery.

Device validation is still required: background and foreground during download,
import, signing, archive preparation and installation; repeat near the last item.
The replacement activity should retain the batch count and current progress.
Repeat with more than one workflow active, and with a real failed item. Confirm
completed batches do not reappear and app-level cancellation still works.

iOS owns the activity and can expire its runtime. There is no public visibility
query for this system-owned activity, so a true background-to-foreground return
renews all active leases, including apparently healthy ones. Interruption-only
activation (such as closing a permission prompt) only retries missing requests.
This recovers in-process batches, not work lost when the app itself crashes or
is force-quit. The OS may still show an expired lease as failed; that event no
longer makes the underlying batch fail.

Local install prompts now wait for the batch's continued-processing launch
callback, rather than submission acceptance. Grant tests cover queued requests,
launch, expiration, cancelled waits, ended batches, submission rejection and
foreground retry. On device, verify a 100-app manifest still opens one prompt,
no prompt opens before `background_workflow_launched`, queued waits remain
cancellable, and cancel/retry cannot open stale prompts. A grant can still be
revoked by iOS after the prompt opens; this change only gates the initial handoff.
Foreground renewal closes the grant gate immediately, including while retirement
of the old task is still queued behind scheduler submissions.
