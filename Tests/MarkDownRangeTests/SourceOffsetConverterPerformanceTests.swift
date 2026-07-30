//
//  SourceOffsetConverterPerformanceTests.swift
//  MarkDownRangeTests
//

import Foundation
import Testing
@testable import MarkDownRange

@Suite struct SourceOffsetConverterPerformanceTests {
	@Test func largeASCIIConstructionBaseline() {
		let source = (0..<20_000)
			.map { "Plain ASCII line \($0) with ordinary editor text." }
			.joined(separator: "\n")
		var converter: SourceOffsetConverter?
		let elapsed = ContinuousClock().measure {
			converter = SourceOffsetConverter(source)
		}
		print("Large ASCII source converter: \(elapsed)")
		#expect(converter?.usesIdentityByteMapping == true)
		#expect(elapsed < .milliseconds(250))
	}

	@Test func unicodeConstructionRetainsExplicitByteMapping() {
		let converter = SourceOffsetConverter("ASCII\nemoji 😀\nend")

		#expect(converter.usesIdentityByteMapping == false)
		#expect(converter.utf16Offset(line: 2, column: 7) == 12)
		#expect(converter.utf16Offset(line: 3, column: 1) == 15)
	}
}
