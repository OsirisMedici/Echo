import XCTest
@testable import SpeakEasy

final class KarenConfigurationTests: XCTestCase {
    func testExistingSettingsDecodeWithoutNewSections() throws {
        let config = try JSONDecoder().decode(GlobalConfig.self, from: Data("{\"defaults\":{\"provider\":\"system\"}}".utf8))
        XCTAssertEqual(config.defaults?.provider, "system")
        XCTAssertNil(config.shortcuts)
        XCTAssertNil(config.karen)
    }
    func testVoiceAndShortcutSurviveSettingsRoundTrip() throws {
        var config = GlobalConfig()
        config.karen = .init(voice: "102")
        config.shortcuts = .init(listening: "optionZ")
        let restored = try JSONDecoder().decode(GlobalConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(restored.karen?.voice, "102")
        XCTAssertEqual(ListeningShortcut(rawValue: restored.shortcuts?.listening ?? ""), .optionZ)
    }
    func testKarenVoiceOverridesStayLocal() throws {
        let base = SpeechNarrationConfiguration(provider: "karen", voice: "0", model: nil, apiKey: "", instructions: nil, rate: 180)
        let lane = VoiceLane(number: 1, task: ListeningTaskLock(id: "test", title: "Test", cwd: "/tmp"), voiceOverride: LaneVoiceOverride(provider: "karen", voiceID: "100"))
        XCTAssertEqual(base.applying(lane: lane).provider, "karen")
        XCTAssertEqual(base.applying(lane: lane).voice, "100")
        XCTAssertEqual(base.applying(lane: lane).apiKey, "")
    }
}
