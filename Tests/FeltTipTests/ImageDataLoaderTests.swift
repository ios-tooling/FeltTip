import Foundation
import Testing
@testable import FeltTip

@Suite("Image data loading")
struct ImageDataLoaderTests {
	@Test("Remote image sessions cap idle and total transfer time")
	func remoteDeadlines() {
		let configuration = ImageDataLoader.sessionConfiguration()
		#expect(configuration.timeoutIntervalForRequest == ImageDataLoader.requestTimeout)
		#expect(configuration.timeoutIntervalForResource == ImageDataLoader.resourceTimeout)
		#expect(configuration.timeoutIntervalForResource == 30)
	}

	@Test("A stalled local image read times out")
	func stalledLocalReadTimesOut() async {
		let gate = DispatchSemaphore(value: 0)
		do {
			_ = try await ImageDataLoader.data(
				from: URL(filePath: "/Volumes/disconnected/image.png"),
				localTimeout: .milliseconds(20)) { _ in
					_ = gate.wait(timeout: .now() + 10)
					return Data()
				}
			Issue.record("Expected a timeout")
		} catch let error as URLError {
			#expect(error.code == .timedOut)
		} catch {
			Issue.record("Unexpected error: \(error)")
		}
		gate.signal()
	}
}
