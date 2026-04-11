//
//  EmojiShortcodes.swift
//  MarkDownRange
//

import Foundation

public enum EmojiShortcodes {
	public static func process(_ text: String) -> String {
		guard text.contains(":") else { return text }
		return text.replacing(/:([a-z0-9_+-]+):/) { match in
			lookup[String(match.1)] ?? String(match.0)
		}
	}

	// Common emoji shortcodes (GitHub/Slack compatible subset)
	static let lookup: [String: String] = [
		"smile": "😄", "laughing": "😆", "blush": "😊", "smiley": "😃",
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
