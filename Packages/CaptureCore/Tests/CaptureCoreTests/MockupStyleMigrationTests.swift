import CoreGraphics
import Foundation
import Testing

@testable import CaptureCore

struct MockupStyleMigrationTests {
    @Test func decodesStyleThatPredatesBorderFields() throws {
        var original = MockupPreset.sunset.style
        original.version = 1

        let encoded = try JSONEncoder().encode(original)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "borderWidthRatio")
        object.removeValue(forKey: "borderColor")

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(MockupStyle.self, from: legacyData)

        var expected = original
        expected.version = 2
        #expect(decoded == expected)
        #expect(decoded.version == 2)
        #expect(decoded.borderWidthRatio == 0)
        #expect(decoded.borderColor == .automatic)
        #expect(decoded.background == original.background)
    }

    @Test func borderFieldsRoundTrip() throws {
        var style = MockupPreset.dark.style
        style.borderWidthRatio = 0.0012
        style.borderColor = .custom(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.4)

        let data = try JSONEncoder().encode(style)
        let decoded = try JSONDecoder().decode(MockupStyle.self, from: data)

        #expect(decoded == style)
        #expect(decoded.version == 2)
        #expect(decoded.borderWidthRatio == 0.0012)
        #expect(decoded.borderColor == .custom(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.4))
    }

    @Test func unknownKeysAreIgnored() throws {
        let style = MockupPreset.light.style
        let encoded = try JSONEncoder().encode(style)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["futureField"] = "ignored"

        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(MockupStyle.self, from: data)

        #expect(decoded == style)
    }

    @Test func transparentBackgroundIsReported() {
        #expect(MockupPreset.transparent.style.isTransparent)
        #expect(MockupPreset.float.style.isTransparent)
        #expect(!MockupPreset.light.style.isTransparent)
        #expect(!MockupPreset.sunset.style.isTransparent)
    }
}
