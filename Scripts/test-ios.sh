#!/bin/bash
#
# Runs the framework's test suite against an iOS Simulator.
#
# `swift test` only ever runs on the host, so the iOS side needs xcodebuild and
# the package's own -Package scheme (the plain MarkDownRange scheme has no test
# action). Serial by choice: the WKWebView-backed suites are very sensitive to
# machine load, and a parallel run on a busy machine produces page-load timeouts
# that look exactly like real failures.
#
# Usage: Scripts/test-ios.sh [simulator-name-or-udid]

set -o pipefail

DEVICE="${1:-iPhone 17 Pro}"
if [[ "$DEVICE" =~ ^[0-9A-F-]{36}$ ]]; then
	DESTINATION="platform=iOS Simulator,id=$DEVICE"
else
	DESTINATION="platform=iOS Simulator,name=$DEVICE"
fi

# Suites excluded on iOS, and why. None of these are silent: a run that skips
# work should say so, or the green result means less than it looks like.
#
#   (EditBridgePasteTests and EditBridgeFuzzTests used to be skipped here for
#    the responder chain, then for paste authorization, then for the clipboard
#    read. All three are addressed — see MarkdownPasteboard and
#    CoordinatorBridgeHarness.clipboardCommand — and both suites now run.)
#   EditBridgeSoakTests    – long-running; the coverage is exhaustiveness, which
#   BlockPatchBenchmark…   – macOS already provides far faster.
#   EditingLatencyBenchmark– wall-clock budgets, meaningless on a simulator.
SKIPS=(
	EditBridgeSoakTests
	BlockPatchBenchmarkTests
	EditingLatencyBenchmarkTests
)

ARGS=()
for suite in "${SKIPS[@]}"; do
	ARGS+=("-skip-testing:MarkDownRangeTests/$suite")
done

echo "iOS destination: $DESTINATION"
echo "skipping: ${SKIPS[*]}"

xcodebuild test \
	-scheme MarkDownRange-Package \
	-destination "$DESTINATION" \
	-parallel-testing-enabled NO \
	CODE_SIGNING_ALLOWED=NO \
	"${ARGS[@]}" 2>&1 | grep -E "Test run with|✘|error:|TEST SUCCEEDED|TEST FAILED"
