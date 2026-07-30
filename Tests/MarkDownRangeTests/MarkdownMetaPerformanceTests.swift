//
//  MarkdownMetaPerformanceTests.swift
//  MarkDownRangeTests
//

import Foundation
import Testing
@testable import MarkDownRange

@Suite struct MarkdownMetaPerformanceTests {
	@Test func largeTextBookkeepingBaseline() {
		let source = (0..<20_000)
			.map { "Ordinary metadata words on line \($0)." }
			.joined(separator: "\n")
		let elapsed = ContinuousClock().measure {
			_ = MarkdownMeta(text: source, blocks: [])
		}
		print("Large MarkdownMeta bookkeeping: \(elapsed)")
		#expect(elapsed < .milliseconds(500))
	}
}
