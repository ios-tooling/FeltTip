import Foundation

/// Runs potentially blocking synchronous work away from the caller while an
/// independent GCD queue enforces the deadline. Keeping both pieces off the
/// Swift cooperative executor prevents several blocked filesystem calls from
/// starving the timeout tasks that are meant to release their callers.
enum BoundedSynchronousWork {
	private final class CancellationHandles: @unchecked Sendable {
		let worker: DispatchWorkItem
		let deadline: DispatchWorkItem

		init(worker: DispatchWorkItem, deadline: DispatchWorkItem) {
			self.worker = worker
			self.deadline = deadline
		}
	}

	private static let timeoutQueue = DispatchQueue(
		label: "com.ios-tooling.felttip.bounded-synchronous-work-timeouts",
		qos: .userInitiated)

	static func run<Value: Sendable>(
		timeout: Duration,
		operation: @escaping @Sendable () throws -> Value
	) async throws -> Value {
		try Task.checkCancellation()
		let (stream, continuation) = AsyncThrowingStream<Value, Error>.makeStream(
			bufferingPolicy: .bufferingNewest(1))
		let worker = DispatchWorkItem {
			do {
				continuation.yield(try operation())
				continuation.finish()
			} catch {
				continuation.finish(throwing: error)
			}
		}
		DispatchQueue.global(qos: .userInitiated).async(execute: worker)
		let deadline = DispatchWorkItem {
			continuation.finish(throwing: URLError(.timedOut))
		}
		timeoutQueue.asyncAfter(
			deadline: .now() + dispatchInterval(for: timeout),
			execute: deadline)
		let handles = CancellationHandles(worker: worker, deadline: deadline)
		return try await withTaskCancellationHandler {
			defer {
				handles.worker.cancel()
				handles.deadline.cancel()
			}
			var iterator = stream.makeAsyncIterator()
			guard let value = try await iterator.next() else {
				throw URLError(.unknown)
			}
			return value
		} onCancel: {
			handles.worker.cancel()
			handles.deadline.cancel()
			continuation.finish(throwing: CancellationError())
		}
	}

	private static func dispatchInterval(for duration: Duration) -> DispatchTimeInterval {
		let components = duration.components
		let (secondsAsNanoseconds, secondsOverflow) = components.seconds
			.multipliedReportingOverflow(by: 1_000_000_000)
		let fractionalNanoseconds = components.attoseconds / 1_000_000_000
		let (nanoseconds, additionOverflow) = secondsAsNanoseconds
			.addingReportingOverflow(fractionalNanoseconds)
		guard !secondsOverflow, !additionOverflow else { return .never }
		return .nanoseconds(Int(clamping: max(0, nanoseconds)))
	}
}
