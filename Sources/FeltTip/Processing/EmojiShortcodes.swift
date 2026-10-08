//
//  EmojiShortcodes.swift
//  FeltTip
//

import Foundation

public enum EmojiShortcodes {
	/// Replaces `:name:` shortcodes with their emoji. Equivalent to replacing
	/// every leftmost `:([a-z0-9_+-]+):` match whose name is known and leaving
	/// unknown ones in place (an unknown match still consumes its closing
	/// colon), but as a single byte scan: the regex form cost ~24 ms per
	/// display render of a 375 KB document that contains no shortcodes at all.
	public static func process(_ text: String) -> String {
		MarkdownCodeProtection.transform(text) { processUnprotected($0) } ?? text
	}

	private static func processUnprotected(_ text: String) -> String {
		var copy = text
		let replaced: String? = copy.withUTF8 { bytes in
			guard bytes.contains(0x3A) else { return nil }
			var out: [UInt8] = []
			var copiedUpTo = 0
			var changed = false
			var i = 0
			while i < bytes.count {
				guard bytes[i] == 0x3A else { i += 1; continue }
				var j = i + 1
				while j < bytes.count, isShortcodeByte(bytes[j]) { j += 1 }
				guard j > i + 1, j < bytes.count, bytes[j] == 0x3A else { i += 1; continue }
				if let emoji = lookup[String(decoding: bytes[(i + 1)..<j], as: UTF8.self)] {
					if !changed { out.reserveCapacity(bytes.count); changed = true }
					out.append(contentsOf: bytes[copiedUpTo..<i])
					out.append(contentsOf: emoji.utf8)
					copiedUpTo = j + 1
				}
				i = j + 1
			}
			guard changed else { return nil }
			out.append(contentsOf: bytes[copiedUpTo...])
			return String(decoding: out, as: UTF8.self)
		}
		return replaced ?? text
	}

	/// `[a-z0-9_+-]`
	@inline(__always) private static func isShortcodeByte(_ b: UInt8) -> Bool {
		(b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) || b == 0x5F || b == 0x2B || b == 0x2D
	}

	// Common emoji shortcodes (GitHub/Slack compatible subset)
	static let lookup: [String: String] = [
		"smile": "😄", "laughing": "😆", "blush": "😊", "smiley": "😃",
		"yum": "😋", "stuck_out_tongue": "😛", "stuck_out_tongue_winking_eye": "😜",
		"grinning": "😀", "wink": "😉", "heart_eyes": "😍", "kissing_heart": "😘",
		"joy": "😂", "rofl": "🤣", "thinking": "🤔", "sunglasses": "😎",
		"cry": "😢", "sob": "😭", "angry": "😠", "rage": "🤬",
		"thumbsup": "👍", "+1": "👍", "thumbsdown": "👎", "-1": "👎",
		"clap": "👏", "wave": "👋", "pray": "🙏", "muscle": "💪",
		"heart": "❤️", "broken_heart": "💔", "fire": "🔥", "star": "⭐",
		"sparkles": "✨", "tada": "🎉", "party_popper": "🎉", "confetti_ball": "🎊",
		"rocket": "🚀", "airplane": "✈️", "car": "🚗", "house": "🏠",
		"warning": "⚠️", "x": "❌", "white_check_mark": "✅", "check": "✔️",
		"question": "❓", "exclamation": "❗", "bulb": "💡", "memo": "📝",
		"book": "📖", "bookmark": "🔖", "link": "🔗", "email": "📧",
		"phone": "📱", "computer": "💻", "keyboard": "⌨️", "camera": "📷",
		"mag": "🔍", "lock": "🔒", "unlock": "🔓", "key": "🔑",
		"hammer": "🔨", "wrench": "🔧", "gear": "⚙️", "bug": "🐛",
		"zap": "⚡", "boom": "💥", "100": "💯", "moneybag": "💰",
		"clock": "🕐", "hourglass": "⏳", "calendar": "📅", "chart": "📊",
		"trophy": "🏆", "medal": "🏅", "crown": "👑", "gem": "💎",
		"globe": "🌍", "earth_americas": "🌎", "sun": "☀️", "moon": "🌙",
		"cloud": "☁️", "rainbow": "🌈", "snowflake": "❄️", "umbrella": "☂️",
		"dog": "🐕", "cat": "🐈", "pizza": "🍕", "coffee": "☕",
		"beer": "🍺", "wine_glass": "🍷", "apple": "🍎", "seedling": "🌱",
		"tree": "🌳", "flower": "🌸", "rose": "🌹", "eyes": "👀",
		"point_right": "👉", "point_left": "👈", "point_up": "👆", "point_down": "👇",
		"ok_hand": "👌", "v": "✌️", "crossed_fingers": "🤞", "metal": "🤘",
		"information_source": "ℹ️", "abc": "🔤", "arrow_right": "➡️", "arrow_left": "⬅️",
		"arrow_up": "⬆️", "arrow_down": "⬇️", "heavy_plus_sign": "➕", "heavy_minus_sign": "➖",
	]
}
