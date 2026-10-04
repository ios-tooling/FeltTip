import Foundation
import Testing
@testable import FeltTip

@Suite("Bounded synchronous work")
struct BoundedSynchronousWorkTests {
	@Test("Concurrent stalled operations cannot starve their deadlines")
	func concurrentStallsTimeOut() async {
		let count = 32
		let gate = DispatchSemaphore(value: 0)
		let timedOut = await withTaskGroup(of: Bool.self) { group in
			for _ in 0..<count {
				group.addTask {
					do {
						let _: Int = try await BoundedSynchronousWork.run(
							timeout: .milliseconds(20)) {
								_ = gate.wait(timeout: .now() + 10)
								return 1
							}
						return false
					} catch let error as URLError {
						return error.code == .timedOut
					} catch {
						return false
					}
				}
			}
			return await group.reduce(into: []) { $0.append($1) }
		}
		for _ in 0..<count { gate.signal() }

		#expect(timedOut.count == count)
		#expect(timedOut.allSatisfy { $0 })
	}
}
