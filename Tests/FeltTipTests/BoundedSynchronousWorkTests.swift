import Foundation
import Testing
@testable import FeltTip

@Suite("Bounded synchronous work")
struct BoundedSynchronousWorkTests {
	@Test("Concurrent stalled operations cannot starve their deadlines")
	func concurrentStallsTimeOut() async {
		let count = 64
		let gate = DispatchSemaphore(value: 0)
		let concurrency = WorkerConcurrencyCounter()
		let timedOut = await withTaskGroup(of: Bool.self) { group in
			for _ in 0..<count {
				group.addTask {
					do {
						let _: Int = try await BoundedSynchronousWork.run(
							timeout: .milliseconds(20)) {
								concurrency.enter()
								defer { concurrency.leave() }
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
		#expect(concurrency.peak <= BoundedSynchronousWork.maximumConcurrentWorkers)
	}
}

private final class WorkerConcurrencyCounter: @unchecked Sendable {
	private let lock = NSLock()
	private var active = 0
	private var maximum = 0

	var peak: Int { lock.withLock { maximum } }

	func enter() {
		lock.withLock {
			active += 1
			maximum = max(maximum, active)
		}
	}

	func leave() {
		lock.withLock { active -= 1 }
	}
}
