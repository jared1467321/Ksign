#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
if ! command -v swiftc >/dev/null || [[ "$(uname -s)" != Darwin ]]; then
  echo "Requires macOS with Swift command-line tools." >&2
  exit 2
fi
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/ksign-recovery-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
cat Tests/BackgroundTaskRecovery/Stubs.swift > "$test_dir/Recovery.swift"
sed '/^import BackgroundTasks$/d; /^import UIKit$/d' \
  Ksign/Utilities/BackgroundTaskManager.swift >> "$test_dir/Recovery.swift"
cat Tests/BackgroundTaskRecovery/RecoveryTests.swift >> "$test_dir/Recovery.swift"
swiftc -swift-version 5 -parse-as-library "$test_dir/Recovery.swift" -o "$test_dir/recovery-tests"
"$test_dir/recovery-tests"
