//
//  FindMatchCountTests.swift
//  MarkDownRangeTests
//
//  The find bar's match count.
//

#if os(macOS)
	import Testing
	import WebKit
	@testable import MarkDownRange

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
	}
#endif
