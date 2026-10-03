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
}
