import Foundation

/// Adapts test-only callback APIs that may lose their completion when an
/// underlying WebContent process exits. Keeping a deadline here prevents one
/// failed callback from suspending the entire test run forever.
@MainActor
enum BoundedTestCallbackWaiter {
	static func wait<Value: Sendable>(
		timeout: Duration = .seconds(10),
		start: (@escaping (Result<Value, Error>) -> Void) -> Void
	) async throws -> Value {
		try Task.checkCancellation()
		let (stream, continuation) = AsyncThrowingStream<Value, Error>.makeStream(
			bufferingPolicy: .bufferingNewest(1))
		start { result in
			switch result {
			case .success(let value):
				continuation.yield(value)
				continuation.finish()
			case .failure(let error):
				continuation.finish(throwing: error)
			}
		}
		let timeoutTask = Task { @MainActor in
			do { try await Task.sleep(for: timeout) }
			catch { return }
			continuation.finish(throwing: URLError(.timedOut))
		}
		return try await withTaskCancellationHandler {
			defer { timeoutTask.cancel() }
			var iterator = stream.makeAsyncIterator()
			guard let value = try await iterator.next() else { throw URLError(.unknown) }
			return value
		} onCancel: {
			continuation.finish(throwing: CancellationError())
		}
	}
}
