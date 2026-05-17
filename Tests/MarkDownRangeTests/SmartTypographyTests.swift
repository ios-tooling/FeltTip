import Testing
@testable import MarkDownRange

@Suite struct SmartTypographyTests {
	@Test func copyrightUpper() {
		#expect(SmartTypography.process("Copyright (C) Acme") == "Copyright © Acme")
	}

	@Test func copyrightLower() {
		#expect(SmartTypography.process("(c) 2026") == "© 2026")
	}

	@Test func registeredAndTrademark() {
		#expect(SmartTypography.process("Brand(r) Thing(tm)") == "Brand® Thing™")
		#expect(SmartTypography.process("Brand(R) Thing(TM)") == "Brand® Thing™")
	}

	@Test func phonogram() {
		#expect(SmartTypography.process("(p) 2026") == "℗ 2026")
	}

	@Test func plusMinus() {
		#expect(SmartTypography.process("10+-2") == "10±2")
	}

	@Test func threeDotsBecomesEllipsis() {
		#expect(SmartTypography.process("test...") == "test…")
	}

	@Test func twoDotsLeftAlone() {
		#expect(SmartTypography.process("test..") == "test..")
	}

	@Test func existingEllipsisLeftAlone() {
		#expect(SmartTypography.process("test…") == "test…")
	}

	@Test func ellipsisFollowedByDotsKeepsTrailing() {
		// `test…..` has an ellipsis (one char) plus 2 periods — only 2 consecutive
		// periods, so it should be untouched.
		#expect(SmartTypography.process("test…..") == "test…..")
	}

	@Test func runOfFourDotsCollapsesAndKeepsExtra() {
		#expect(SmartTypography.process("test....") == "test….")
	}

	@Test func skipsFencedCodeBlocks() {
		let md = """
		```
		(c) keep me as-is
		```
		Outside (c)
		"""
		let expected = """
		```
		(c) keep me as-is
		```
		Outside ©
		"""
		#expect(SmartTypography.process(md) == expected)
	}

	@Test func skipsInlineCode() {
		#expect(SmartTypography.process("Use `(c)` to print copyright") == "Use `(c)` to print copyright")
	}
}
