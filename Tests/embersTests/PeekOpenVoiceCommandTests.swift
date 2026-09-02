import Foundation
import XCTest
@testable import embers

final class PeekOpenVoiceCommandTests: XCTestCase {
    func testFeatureFlagDefaultsOffAndRequiresExplicitEnvironmentOptIn() {
        XCTAssertFalse(AppFeatureFlags().voiceOpenSinglePeek)
        XCTAssertFalse(AppFeatureFlags.from(environment: [:]).voiceOpenSinglePeek)
        XCTAssertFalse(AppFeatureFlags.from(environment: [
            AppFeatureFlags.voiceOpenSinglePeekEnvironmentKey: "true"
        ]).voiceOpenSinglePeek)
        XCTAssertTrue(AppFeatureFlags.from(environment: [
            AppFeatureFlags.voiceOpenSinglePeekEnvironmentKey: "1"
        ]).voiceOpenSinglePeek)
    }

    func testOpenCommandIsDisabledByDefault() {
        let result = PeekOpenVoiceCommand.resolve(
            .init(text: "open", isFinal: true),
            visiblePeeks: [peek(id: "only")]
        )

        XCTAssertEqual(result, .notACommand)
    }

    func testFinalOpenResolvesTheOnlyVisiblePeek() {
        let onlyPeek = peek(id: "only")

        let result = PeekOpenVoiceCommand.resolve(
            .init(text: "Open.", isFinal: true),
            visiblePeeks: [onlyPeek],
            isEnabled: true
        )

        XCTAssertEqual(result, .open(onlyPeek))
    }

    func testPartialOpenIsHeld() {
        let result = PeekOpenVoiceCommand.resolve(
            .init(text: "open", isFinal: false),
            visiblePeeks: [peek(id: "only")],
            isEnabled: true
        )

        XCTAssertEqual(result, .held(peek(id: "only")))
    }

    func testFinalOpenAbstainsWhenMoreThanOnePeekIsVisible() {
        let result = PeekOpenVoiceCommand.resolve(
            .init(text: "open", isFinal: true),
            visiblePeeks: [peek(id: "first"), peek(id: "second")],
            isEnabled: true
        )

        XCTAssertEqual(result, .ambiguous)
    }

    func testOpenWithoutAVisiblePeekRemainsAvailableToNormalRouting() {
        let result = PeekOpenVoiceCommand.resolve(
            .init(text: "open", isFinal: true),
            visiblePeeks: [],
            isEnabled: true
        )

        XCTAssertEqual(result, .notACommand)
    }

    func testLongerFinalUtteranceRemainsAvailableToNormalRouting() {
        let result = PeekOpenVoiceCommand.resolve(
            .init(text: "open the project notes", isFinal: true),
            visiblePeeks: [peek(id: "only")],
            isEnabled: true
        )

        XCTAssertEqual(result, .notACommand)
    }

    func testCommandTextStartsAfterTheTranscriptThatProducedThePeek() {
        let utteranceID = UUID()
        let text = PeekOpenVoiceCommand.textAfterPeek(
            in: .init(
                text: "Show me Second Brain, open",
                isFinal: false,
                utteranceID: utteranceID
            ),
            prefix: (utteranceID, "show me second brain")
        )

        XCTAssertEqual(text, "open")
    }

    func testCorrectedPrefixFailsClosedInsteadOfExtractingOpen() {
        let utteranceID = UUID()
        let text = PeekOpenVoiceCommand.textAfterPeek(
            in: .init(
                text: "Show the second brain open",
                isFinal: false,
                utteranceID: utteranceID
            ),
            prefix: (utteranceID, "show me second brain")
        )

        XCTAssertEqual(text, "show the second brain open")
    }

    func testPrefixFromAnotherUtteranceCannotAuthorizeOpen() {
        let text = PeekOpenVoiceCommand.textAfterPeek(
            in: .init(
                text: "open",
                isFinal: true,
                utteranceID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
            ),
            prefix: (
                UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                "show me second brain"
            )
        )

        XCTAssertEqual(text, "open")
    }

    func testConversationalUsesOfOpenNeverBecomeTheSolePeekCommand() {
        let visible = [peek(id: "only")]
        let utterances = [
            "openly",
            "reopen",
            "open it",
            "please open",
            "open the item",
            "the door is open",
        ]

        for utterance in utterances {
            XCTAssertEqual(
                PeekOpenVoiceCommand.resolve(
                    .init(text: utterance, isFinal: true),
                    visiblePeeks: visible,
                    isEnabled: true
                ),
                .notACommand,
                "Unexpected command for: \(utterance)"
            )
        }
    }

    private func peek(id: String) -> Peek {
        Peek(
            id: id,
            target: .init(phrase: id, ref: .node("node-\(id)"), title: id),
            title: id,
            bornAt: Date(timeIntervalSince1970: 0)
        )
    }
}
