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
#   EditBridgePasteTests   – three causes, two of them now fixed. The tests no
#                            longer drive `paste:` through the responder chain
#                            (a library bundle has no UIApplication, so the
#                            action never arrived) — CoordinatorBridgeHarness
#                            .clipboardCommand dispatches `beforeinput` from the
#                            page on iOS instead. The test's own pasteboard read
#                            no longer prompts either (see TestPasteboard).
#                            What still hangs is the *bridge's* read:
#                            MarkdownWebViewEditBridge asks for
#                            UIPasteboard.general.string on the main actor while
#                            handling op:'paste', iOS gates that read behind
#                            paste authorization the test host cannot answer, and
#                            the blocked main actor takes the evaluateJavaScript
#                            completion — and the whole suite — down with it.
#                            The first test never finishes. Fixing it means the
#                            bridge reading the pasteboard without blocking.
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
