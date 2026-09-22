#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
if [[ "$(uname -s)" != Linux ]]; then
  echo "Requires Linux (/proc/self/maps), clang++, and OpenSSL headers." >&2
  exit 2
fi
test_dir=$(mktemp -d /tmp/ksign-cleanup-tests.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
core=ZsignLatest/Sources/ZsignC/Core
clang++ -std=c++17 -ffunction-sections -fdata-sections \
  -I "$core" -I "$core/common" \
  Tests/BatchCleanup/MachOMappingTests.cpp \
  "$core/macho.cpp" "$core/archo.cpp" \
  "$core/signing.cpp" "$core/common/util.cpp" \
  "$core/common/fs.cpp" "$core/common/log.cpp" \
  -Wl,--gc-sections -o "$test_dir/mapping-tests"
"$test_dir/mapping-tests"
