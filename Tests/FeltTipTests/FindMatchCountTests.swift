//
//  FindMatchCountTests.swift
//  FeltTipTests
//
//  The find bar's match count.
//

#if os(macOS)
	import AppKit
	import Testing
	import WebKit
	@testable import FeltTip

	@Suite(.serialized) @MainActor struct FindMatchCountTests {
		private func host(_ markdown: String) async throws -> MarkdownWebViewFindHost {
			let harness = try await CoordinatorBridgeHarness(source: markdown)
			return MarkdownWebViewFindHost(webView: harness.webView)
		}

		/// Wait for the label to settle — the count round-trips through the page.
		private func count(
			of term: String, in host: MarkdownWebViewFindHost
		) async throws -> String {
			host.updateMatchCount(for: term)
			for _ in 0..<40 {
				try await Task.sleep(for: .milliseconds(50))
				if !host.matchCountLabel.stringValue.isEmpty || term.isEmpty {
					return host.matchCountLabel.stringValue
				}
			}
			return host.matchCountLabel.stringValue
		}

		@Test func labelsReadAsEnglishRatherThanADigit() {
			#expect(MarkdownWebViewFindHost.label(for: 0) == "No results")
			#expect(MarkdownWebViewFindHost.label(for: 1) == "1 result")
			#expect(MarkdownWebViewFindHost.label(for: 7) == "7 results")
		}

		@Test func countsEveryOccurrenceCaseInsensitively() async throws {
			let host = try await host("alpha Alpha ALPHA beta\n")
			#expect(try await count(of: "alpha", in: host) == "3 results")
		}

		@Test func searchesTheRenderedTextNotTheMarkdownSource() async throws {
			// The styled view hides the markers, so `bold` is one match — the
			// word — and `**` is not text the user can search for at all.
			let host = try await host("a **bold** b\n")
			#expect(try await count(of: "bold", in: host) == "1 result")
			#expect(try await count(of: "**", in: host) == "No results")
		}

		@Test func anEmptyTermClearsTheLabel() async throws {
			let host = try await host("alpha beta\n")
			#expect(try await count(of: "alpha", in: host) == "1 result")
			#expect(try await count(of: "", in: host) == "")
		}

		@Test func countsOverlappingCandidatesTheWayAFindStepsThroughThem() async throws {
			// "aaaa" holds two non-overlapping "aa", which is what Find would
			// walk — not three.
			let host = try await host("aaaa\n")
			#expect(try await count(of: "aa", in: host) == "2 results")
		}

		@Test func recountsWhenHostReplacesTheRenderedDocument() async throws {
			let harness = try await CoordinatorBridgeHarness(source: "Aster Ω appears once.\n")
			let host = harness.installFindHost()
			let item = NSMenuItem()
			item.tag = NSTextFinder.Action.showFindInterface.rawValue
			host.performTextFinderAction(item)
			let field = try #require(host.subviews
				.flatMap(\.subviews).compactMap { $0 as? NSSearchField }.first)
			field.stringValue = "Aster Ω"
			field.sendAction(field.action, to: field.target)
			try await waitForCount("1 result", in: host)

			try await harness.replaceExternally("Aster Ω appears twice: Aster Ω.\n")
			try await waitForCount("2 results", in: host)
		}

		@Test func recountsAfterAnInPlaceStyledEdit() async throws {
			let harness = try await CoordinatorBridgeHarness(source: "Aster once.\n")
			let host = harness.installFindHost()
			let item = NSMenuItem()
			item.tag = NSTextFinder.Action.showFindInterface.rawValue
			host.performTextFinderAction(item)
			let field = try #require(host.subviews
				.flatMap(\.subviews).compactMap { $0 as? NSSearchField }.first)
			field.stringValue = "Aster"
			field.sendAction(field.action, to: field.target)
			try await waitForCount("1 result", in: host)

			try await harness.type(" Aster", at: 5)
			#expect(harness.source == "Aster Aster once.\n")
			try await waitForCount("2 results", in: host)
		}

		private func waitForCount(_ expected: String, in host: MarkdownWebViewFindHost) async throws {
			for _ in 0..<80 {
				if host.matchCountLabel.stringValue == expected { return }
				try await Task.sleep(for: .milliseconds(50))
			}
			#expect(host.matchCountLabel.stringValue == expected)
		}
	}
#endif
