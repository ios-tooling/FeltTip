import Foundation
import Testing
@testable import FeltTip

@Suite("Bounded test callbacks")
@MainActor
struct BoundedTestCallbackWaiterTests {
	@Test("A lost callback times out")
	func lostCallback() async {
		do {
			let _: Int = try await BoundedTestCallbackWaiter.wait(timeout: .milliseconds(20)) { _ in }
			Issue.record("Expected the callback wait to time out")
		} catch let error as URLError {
			#expect(error.code == .timedOut)
		} catch {
			Issue.record("Unexpected error: \(error)")
		}
	}

	@Test("A delivered callback returns its value")
	func deliveredCallback() async throws {
		let value: Int = try await BoundedTestCallbackWaiter.wait(timeout: .seconds(1)) {
			$0(.success(42))
		}
		#expect(value == 42)
	}
}
