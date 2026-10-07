//
//  TestConcurrencyLimiter.swift
//  FeltTipTests
//

import Foundation
import Testing

/// A main-actor counting semaphore for test resources that must not pile up,
/// such as live WebKit pages. Swift Testing has no cross-suite serialization,
/// so suites that each pass alone can still starve one another when the
/// runner interleaves them all on the main actor.
///
/// Fails open: a waiter that has been queued for a long time proceeds anyway
/// and records an issue, so a leaked holder cannot deadlock the whole run.
@MainActor
final class TestConcurrencyLimiter {
	private let capacity: Int
	private let name: String
	private var inUse = 0
	private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Never>)] = []

	init(capacity: Int, name: String) {
		self.capacity = capacity
		self.name = name
	}

	func acquire() async {
		if inUse < capacity {
			inUse += 1
			return
		}
		let id = UUID()
		let timeout = Task { @MainActor [weak self] in
			try? await Task.sleep(for: .seconds(30))
			guard let self, let index = waiters.firstIndex(where: { $0.id == id }) else { return }
			let waiter = waiters.remove(at: index)
			inUse += 1
			Issue.record("\(name): waited 30s for a slot; proceeding over the cap of \(capacity)")
			waiter.continuation.resume()
		}
		await withCheckedContinuation { continuation in
			waiters.append((id, continuation))
		}
		timeout.cancel()
	}

	/// Hands the slot straight to the next waiter when there is one.
	func release() {
		if waiters.isEmpty {
			inUse -= 1
		} else {
			waiters.removeFirst().continuation.resume()
		}
	}
}
