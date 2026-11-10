import Foundation
import Testing
@testable import CaptureCore

struct MockupPolicyTests {
    @Test func appliesToAreaAndFullscreenButNotWindowOrScroll() {
        #expect(MockupPolicy.applies(captureMode: .area(nil), isPinning: false, isEnabled: true))
        #expect(MockupPolicy.applies(captureMode: .fullscreen, isPinning: false, isEnabled: true))
        #expect(!MockupPolicy.applies(captureMode: .window(nil), isPinning: false, isEnabled: true))
        #expect(!MockupPolicy.applies(captureMode: .scroll, isPinning: false, isEnabled: true))
    }

    @Test func pinningNeverAppliesEvenForArea() {
        #expect(!MockupPolicy.applies(captureMode: .area(nil), isPinning: true, isEnabled: true))
    }

    @Test func disabledNeverApplies() {
        #expect(!MockupPolicy.applies(captureMode: .fullscreen, isPinning: false, isEnabled: false))
    }

    @Test func styleRoundTripsThroughJSON() throws {
        let style = MockupPreset.sunset.style
        let data = try JSONEncoder().encode(style)
        let decoded = try JSONDecoder().decode(MockupStyle.self, from: data)

        #expect(decoded == style)
        #expect(decoded.version == 1)
    }

    @Test func unknownPresetFallsBackToLight() {
        #expect(MockupPolicy.preset(for: "nope") == .light)
    }
}
