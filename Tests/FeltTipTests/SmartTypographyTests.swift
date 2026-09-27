import Testing
@testable import FeltTip

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

	@Test func preservesHTMLComment() {
		// Without the `<...>` skip, `--` inside an HTML comment gets en-dashed
		// and the CommonMark parser stops recognising it as a type-2 HTML
		// block — the literal text then leaks into the rendered output.
		#expect(SmartTypography.process("<!-- prettier-ignore-start -->") == "<!-- prettier-ignore-start -->")
		#expect(SmartTypography.process("<!--foo-->") == "<!--foo-->")
	}

	@Test func preservesHTMLAttributesWithHyphens() {
		// `data--whatever` inside an attribute would otherwise become `data–whatever`.
		#expect(SmartTypography.process(#"<div data-foo="a--b">"#) == #"<div data-foo="a--b">"#)
	}

	@Test func dashOutsideTagStillConverts() {
		// Sanity: only the tag region is skipped — surrounding dashes still
		// convert, so we don't silently turn the typography pass off.
		#expect(SmartTypography.process("text -- <i>more</i> -- end") == "text – <i>more</i> – end")
	}
}
