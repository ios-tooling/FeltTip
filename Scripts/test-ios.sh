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
#   EditBridgePasteTests   – the paste tests drive `paste:` through the responder
#                            chain, and a library test bundle has no UIApplication
#                            ("This process does not have a UIApplication object
#                            and will not receive events"), so the action never
#                            reaches the web view and the harness waits rather
#                            than failing. Driving paste on iOS means dispatching
#                            `insertFromPaste` from the page instead, which is
#                            the contract the bridge actually implements.
#                            (A second cause, iOS gating a pasteboard read behind
#                            paste authorization the test host can't answer, is
#                            fixed — see TestPasteboard.)
#   EditBridgeFuzzTests    – contains cut/paste fuzz cases, same cause.
#   EditBridgeSoakTests    – long-running; the coverage is exhaustiveness, which
#   BlockPatchBenchmark…   – macOS already provides far faster.
#   EditingLatencyBenchmark– wall-clock budgets, meaningless on a simulator.
SKIPS=(
	EditBridgePasteTests
	EditBridgeFuzzTests
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
