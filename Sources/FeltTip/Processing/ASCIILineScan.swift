//
//  ASCIILineScan.swift
//  FeltTip
//
//  One UTF-8 pass per source line for the merged preprocessor line pass.
//  Records which marker characters the line contains so each per-line
//  processor runs only when it can matter, whether the line is pure ASCII
//  (the byte-level fast paths apply) and where its whitespace trim falls.
//

import Foundation

struct ASCIILineScan {
	let isASCII: Bool
	let byteCount: Int
	/// Leading bytes that `CharacterSet.whitespaces` would trim (space, tab).
	let leadingWhitespace: Int
	let trailingWhitespace: Int
	let hasHash: Bool
	let hasCaret: Bool
	let hasTilde: Bool
	let hasPlusPlus: Bool
	let hasEqualsEquals: Bool
	let hasDoubleQuote: Bool
	let hasSingleQuote: Bool
	let hasParen: Bool
	let hasPlusMinus: Bool
	let hasEllipsis: Bool
	let hasDoubleDash: Bool
	/// `:` `;` `8` `=` — the first byte of every emoticon spelling.
	let hasEmoticonSeed: Bool
	let hasOpenBracket: Bool
	let hasOpenBrace: Bool

	init(_ line: Substring) {
		var line = line
		self = line.withUTF8 { bytes in ASCIILineScan(bytes: bytes) }
	}

	init(_ line: String) {
		self.init(Substring(line))
	}

	init(bytes: UnsafeBufferPointer<UInt8>) {
		var ascii = true
		var hash = false, caret = false, tilde = false, plusPlus = false, eqEq = false
		var dq = false, sq = false, paren = false, plusMinus = false, ellipsis = false
		var dashDash = false, seed = false, bracket = false, brace = false
		var previous: UInt8 = 0
		var previous2: UInt8 = 0
		for byte in bytes {
			switch byte {
			case 0x23: hash = true
			case 0x5E: caret = true
			case 0x7E: tilde = true
			case 0x2B: if previous == 0x2B { plusPlus = true }
			case 0x3D: seed = true; if previous == 0x3D { eqEq = true }
			case 0x22: dq = true
			case 0x27: sq = true
			case 0x28: paren = true
			case 0x2D: if previous == 0x2B { plusMinus = true }; if previous == 0x2D { dashDash = true }
			case 0x2E: if previous == 0x2E, previous2 == 0x2E { ellipsis = true }
			case 0x3A, 0x3B, 0x38: seed = true
			case 0x5B: bracket = true
			case 0x7B: brace = true
			default: if byte >= 0x80 { ascii = false }
			}
			previous2 = previous
			previous = byte
		}
		var leading = 0
		while leading < bytes.count, bytes[leading] == 0x20 || bytes[leading] == 0x09 { leading += 1 }
		var trailing = 0
		while trailing < bytes.count - leading,
			  bytes[bytes.count - 1 - trailing] == 0x20 || bytes[bytes.count - 1 - trailing] == 0x09 {
			trailing += 1
		}
		isASCII = ascii
		byteCount = bytes.count
		leadingWhitespace = leading
		trailingWhitespace = trailing
		hasHash = hash; hasCaret = caret; hasTilde = tilde; hasPlusPlus = plusPlus
		hasEqualsEquals = eqEq; hasDoubleQuote = dq; hasSingleQuote = sq; hasParen = paren
		hasPlusMinus = plusMinus; hasEllipsis = ellipsis; hasDoubleDash = dashDash
		hasEmoticonSeed = seed; hasOpenBracket = bracket; hasOpenBrace = brace
	}

	var trimmedIsEmpty: Bool { leadingWhitespace + trailingWhitespace >= byteCount }
}

/// Result of a byte-level processor pass over one line.
enum ASCIILineResult {
	/// The line is not pure ASCII; the caller must use the general path.
	case notASCII
	case unchanged
	case changed(String)
}

enum ASCIIByte {
	/// `Character.isWhitespace` for an ASCII byte: U+0009–U+000D and space.
	@inline(__always) static func isWhitespace(_ b: UInt8) -> Bool {
		b == 0x20 || (b >= 0x09 && b <= 0x0D)
	}
	@inline(__always) static func isLetter(_ b: UInt8) -> Bool {
		(b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
	}
	@inline(__always) static func allASCII(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
		for b in bytes where b >= 0x80 { return false }
		return true
	}
	/// Index of the next `needle` after `start`, or nil.
	@inline(__always) static func indexOf(_ needle: UInt8, in bytes: UnsafeBufferPointer<UInt8>, after start: Int) -> Int? {
		var i = start + 1
		while i < bytes.count {
			if bytes[i] == needle { return i }
			i += 1
		}
		return nil
	}
}

/// Collects a rewritten line lazily: nothing is allocated until the first
/// byte that differs from the input.
struct ASCIILineBuilder {
	private let source: UnsafeBufferPointer<UInt8>
	private var output: [UInt8]?
	/// Bytes of `source` already accounted for (copied or replaced).
	private var consumed = 0

	init(source: UnsafeBufferPointer<UInt8>) {
		self.source = source
	}

	/// Keep `source[consumed..<end]` verbatim.
	mutating func keep(through end: Int) {
		if var out = output {
			out.append(contentsOf: source[consumed..<end])
			output = out
		}
		consumed = end
	}

	/// Replace `source[consumed..<end]` with `bytes`.
	mutating func replace(through end: Int, with bytes: some Sequence<UInt8>) {
		if output == nil {
			var out: [UInt8] = []
			out.reserveCapacity(source.count + 16)
			out.append(contentsOf: source[0..<consumed])
			output = out
		}
		output!.append(contentsOf: bytes)
		consumed = end
	}

	mutating func finish() -> ASCIILineResult {
		keep(through: source.count)
		guard let output else { return .unchanged }
		return .changed(String(decoding: output, as: UTF8.self))
	}
}
