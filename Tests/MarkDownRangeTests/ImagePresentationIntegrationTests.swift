import Foundation
import Testing
@testable import MarkDownRange

@Suite @MainActor struct ImagePresentationIntegrationTests {
	@Test func largeImageButtonSendsAnOpenRequest() async throws {
		let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='800' height='500'><rect width='800' height='500' fill='blue'/></svg>"
		let data = Data(svg.utf8).base64EncodedString()
		var request: MarkdownImageRequest?
		let harness = try await CoordinatorBridgeHarness(
			source: "Fixture\n\n![QA landscape](data:image/svg+xml;base64,\(data))",
			onOpenImage: { request = $0 }
		)

		try await harness.waitUntil("large-image open button") {
			try await harness.evaluate("document.querySelector('.md-image-open-button') ? 'yes' : 'no'") == "yes"
		}
		try await Task.sleep(for: .milliseconds(500))
		#expect(try await harness.evaluate("document.querySelector('.md-image-open-button') ? 'yes' : 'no'") == "yes")
		try await harness.run("document.querySelector('.md-image-open-button').click()")
		try await harness.waitUntil("image open request") { request != nil }

		#expect(request?.altText == "QA landscape")
		#expect(request?.url.absoluteString.hasPrefix("data:image/svg+xml;base64,") == true)
	}

	@Test func smallRenderedImageDoesNotGetAnOpenButton() async throws {
		let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='120' height='80'></svg>"
		let data = Data(svg.utf8).base64EncodedString()
		let harness = try await CoordinatorBridgeHarness(
			source: "Fixture\n\n![Small](data:image/svg+xml;base64,\(data))",
			onOpenImage: { _ in Issue.record("small image unexpectedly opened") }
		)

		try await Task.sleep(for: .milliseconds(500))
		#expect(try await harness.evaluate("document.querySelector('.md-image-open-button') ? 'yes' : 'no'") == "no")
	}

	@Test func pinchOutOverLargeImageSendsAnOpenRequest() async throws {
		let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='800' height='500'></svg>"
		let data = Data(svg.utf8).base64EncodedString()
		var request: MarkdownImageRequest?
		let harness = try await CoordinatorBridgeHarness(
			source: "Fixture\n\n![Pinch target](data:image/svg+xml;base64,\(data))",
			onOpenImage: { request = $0 }
		)
		try await harness.waitUntil("large-image open button") {
			try await harness.evaluate("document.querySelector('.md-image-open-button') ? 'yes' : 'no'") == "yes"
		}

		try await harness.run("""
			var image = document.querySelector('img');
			var rect = image.getBoundingClientRect();
			function gesture(type, scale) {
				var event = new Event(type, { bubbles: true, cancelable: true });
				Object.defineProperties(event, {
					clientX: { value: rect.left + rect.width / 2 },
					clientY: { value: rect.top + rect.height / 2 },
					scale: { value: scale }
				});
				document.dispatchEvent(event);
			}
			gesture('gesturestart', 1);
			gesture('gesturechange', 1.25);
			gesture('gestureend', 1.25);
			""")
		try await harness.waitUntil("pinch image open request") { request != nil }
		#expect(request?.altText == "Pinch target")
	}
}
