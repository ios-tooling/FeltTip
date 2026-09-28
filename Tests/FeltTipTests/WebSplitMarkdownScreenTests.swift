#if os(macOS)
import Testing
@testable import FeltTip

@MainActor
struct WebSplitMarkdownScreenTests {
	@Test("Split editing closes scroll sync before the host changes its binding")
	func editClosesScrollSyncBeforeHostUpdate() {
		var syncIsSuspended = false
		var hostObservedSuspendedSync = false

		MarkdownSplitEditRelay.forward(
			"updated",
			caret: 7,
			beginEditing: { syncIsSuspended = true },
			report: { text, caret in
				hostObservedSuspendedSync = syncIsSuspended
				#expect(text == "updated")
				#expect(caret == 7)
			},
			write: { _ in Issue.record("A host edit must not use the binding fallback") })

		#expect(hostObservedSuspendedSync)
	}

	@Test("Binding-backed split editing also closes scroll sync first")
	func bindingEditClosesScrollSyncBeforeWrite() {
		var syncIsSuspended = false
		var writtenText: String?
		var writeObservedSuspendedSync = false

		MarkdownSplitEditRelay.forward(
			"updated",
			caret: nil,
			beginEditing: { syncIsSuspended = true },
			report: nil,
			write: {
				writeObservedSuspendedSync = syncIsSuspended
				writtenText = $0
			})

		#expect(writeObservedSuspendedSync)
		#expect(writtenText == "updated")
	}
}
#endif
