import AppKit
import SwiftUI
import XCTest
@testable import embers

final class VoiceRoutingStatusPresentationTests: XCTestCase {
    func testOneNumberPresentationDrivesBothCopyAndNotchFromTheSameValue() {
        let generation = ContextProgressPresentation(progress: .init(
            stage: .generatingNotes,
            completed: 8,
            total: 16
        ))
        let validation = ContextProgressPresentation(progress: .init(
            stage: .validatingPhraseChecks,
            completed: 500,
            total: 1_000
        ))

        XCTAssertEqual(generation.valueLabel, "45%")
        XCTAssertEqual(generation.fraction, 0.45)
        XCTAssertEqual(validation.valueLabel, "95%")
        XCTAssertEqual(validation.fraction, 0.95)
        XCTAssertFalse(generation.valueLabel.contains("notes"))
        XCTAssertFalse(validation.valueLabel.contains("checks"))
    }

    func testOverallPercentageIsBoundedAndMonotonicAcrossEveryReportedUnit() {
        let generation = (0...80).map { completed in
            VoiceRoutingCompilationProgress(
                stage: .generatingNotes,
                completed: completed,
                total: 80
            ).overallFraction
        }
        let validation = (0...100).map { completed in
            VoiceRoutingCompilationProgress(
                stage: .validatingPhraseChecks,
                completed: completed,
                total: 100
            ).overallFraction
        }
        let completeRun = generation + validation

        XCTAssertEqual(generation.first, 0)
        XCTAssertEqual(generation.last, 0.9)
        XCTAssertEqual(validation.first, 0.9)
        XCTAssertEqual(validation.last, 1)
        XCTAssertTrue(completeRun.allSatisfy { (0...1).contains($0) })
        XCTAssertTrue(zip(completeRun, completeRun.dropFirst()).allSatisfy { $0 <= $1 })
    }

    func testPercentageLabelAlwaysMatchesTheRoundedNotchFraction() {
        for stage in [
            VoiceRoutingCompilationProgress.Stage.generatingNotes,
            .validatingPhraseChecks,
        ] {
            for completed in 0...37 {
                let progress = VoiceRoutingCompilationProgress(
                    stage: stage,
                    completed: completed,
                    total: 37
                )
                XCTAssertEqual(
                    progress.percentageLabel,
                    "\(Int((progress.overallFraction * 100).rounded()))%"
                )
            }
        }
    }

    @MainActor
    func testLongestCurrentProgressCopyReceivesItsFullIntrinsicWidth() {
        let progress = VoiceRoutingCompilationProgress(
            stage: .validatingPhraseChecks,
            completed: 5_526,
            total: 67_165
        )
        let view = ContextProgressStatus(
            label: "Preparing your notes:",
            progress: progress
        )
        let host = NSHostingView(rootView: view)
        let font = Font.system(size: 10.5, weight: .medium)
        let labelWidth = NSHostingView(rootView: Text("Preparing your notes:").font(font)).fittingSize.width
        let percentageWidth = NSHostingView(
            rootView: Text(progress.percentageLabel).font(font).monospacedDigit()
        ).fittingSize.width

        XCTAssertEqual(
            host.fittingSize.width,
            labelWidth + 16 + percentageWidth,
            accuracy: 1,
            "The row must use one consistent font and its full intrinsic width"
        )
        XCTAssertLessThan(host.fittingSize.width, NotchMetrics.openSize.width)
    }

    func testContextLensActivityUsesTheCompactPreparingLabel() {
        XCTAssertEqual(VoiceRoutingStatus.State.checking.contextLensActivityLabel, "Preparing your notes:")
        XCTAssertEqual(VoiceRoutingStatus.State.building(progress: .init(
            stage: .generatingNotes,
            completed: 0,
            total: 860
        )).contextLensActivityLabel, "Preparing your notes:")
        XCTAssertEqual(VoiceRoutingStatus.State.building(progress: .init(
            stage: .validatingPhraseChecks,
            completed: 0,
            total: 4_300
        )).contextLensActivityLabel, "Preparing your notes:")
    }

    func testSettledStatesDoNotPresentContextLensActivity() {
        XCTAssertNil(VoiceRoutingStatus.State.waitingForContext.contextLensActivityLabel)
        XCTAssertNil(VoiceRoutingStatus.State.ready(
            contextCount: 860,
            phraseCount: 12_000,
            recallWarningCount: 0
        ).contextLensActivityLabel)
        XCTAssertNil(VoiceRoutingStatus.State.namesOnly(reason: "Unavailable").contextLensActivityLabel)
    }

    func testCompilationProgressPresentsOneContinuousOverallPercentage() {
        let notes = VoiceRoutingCompilationProgress(
            stage: .generatingNotes,
            completed: 412,
            total: 860
        )
        XCTAssertEqual(notes.percentageLabel, "43%")
        XCTAssertEqual(notes.overallFraction, (412.0 / 860.0) * 0.9, accuracy: 0.0001)

        let checks = VoiceRoutingCompilationProgress(
            stage: .validatingPhraseChecks,
            completed: 4_218,
            total: 67_165
        )
        XCTAssertEqual(checks.percentageLabel, "91%")
        XCTAssertEqual(
            checks.overallFraction,
            0.9 + (4_218.0 / 67_165.0) * 0.1,
            accuracy: 0.0001
        )

        let overrun = VoiceRoutingCompilationProgress(
            stage: .validatingPhraseChecks,
            completed: 12,
            total: 10
        )
        XCTAssertEqual(overrun.overallFraction, 1)

        let underrun = VoiceRoutingCompilationProgress(
            stage: .generatingNotes,
            completed: -2,
            total: 10
        )
        XCTAssertEqual(underrun.overallFraction, 0)

        let empty = VoiceRoutingCompilationProgress(
            stage: .generatingNotes,
            completed: 0,
            total: 0
        )
        XCTAssertEqual(empty.overallFraction, 0)
    }

    func testStageTransitionHoldsAtNinetyPercentWithoutResetting() {
        let notesComplete = VoiceRoutingCompilationProgress(
            stage: .generatingNotes,
            completed: 841,
            total: 841
        )
        let validationBegins = VoiceRoutingCompilationProgress(
            stage: .validatingPhraseChecks,
            completed: 0,
            total: 67_165
        )
        let validationComplete = VoiceRoutingCompilationProgress(
            stage: .validatingPhraseChecks,
            completed: 67_165,
            total: 67_165
        )

        XCTAssertEqual(notesComplete.overallFraction, 0.9)
        XCTAssertEqual(validationBegins.overallFraction, 0.9)
        XCTAssertEqual(validationComplete.overallFraction, 1)
        XCTAssertEqual(notesComplete.percentageLabel, "90%")
        XCTAssertEqual(validationBegins.percentageLabel, "90%")
        XCTAssertEqual(validationComplete.percentageLabel, "100%")
    }

    func testStageSpecificDetailAndProgressExposureDescribeTheRealWork() {
        let notes = VoiceRoutingCompilationProgress(
            stage: .generatingNotes,
            completed: 10,
            total: 841
        )
        let checks = VoiceRoutingCompilationProgress(
            stage: .validatingPhraseChecks,
            completed: 50,
            total: 4_205
        )
        let generating = VoiceRoutingStatus.State.building(progress: notes)
        let validating = VoiceRoutingStatus.State.building(progress: checks)

        XCTAssertEqual(generating.detail, "Learning grounded phrases for your notes on this Mac")
        XCTAssertEqual(validating.detail, "Checking generated phrases on this Mac")
        XCTAssertEqual(generating.compilationProgress, notes)
        XCTAssertEqual(validating.compilationProgress, checks)
        XCTAssertNil(VoiceRoutingStatus.State.checking.compilationProgress)
        XCTAssertNil(VoiceRoutingStatus.State.ready(
            contextCount: 841,
            phraseCount: 4_205,
            recallWarningCount: 0
        ).compilationProgress)
    }

    @MainActor
    func testStatusAcceptsProgressWhileWorkingButIgnoresLateUpdatesAfterSettling() {
        let status = VoiceRoutingStatus()
        let progress = VoiceRoutingCompilationProgress(
            stage: .generatingNotes,
            completed: 8,
            total: 841
        )

        status.set(.checking)
        status.update(progress)
        XCTAssertEqual(status.state, .building(progress: progress))

        let ready = VoiceRoutingStatus.State.ready(
            contextCount: 841,
            phraseCount: 4_205,
            recallWarningCount: 0
        )
        status.set(ready)
        status.update(.init(stage: .validatingPhraseChecks, completed: 0, total: 4_205))
        XCTAssertEqual(status.state, ready)
    }

    @MainActor
    func testStatusNeverMovesBackwardsWithinAStageOrBackToGeneration() {
        let status = VoiceRoutingStatus()
        let generated = VoiceRoutingCompilationProgress(
            stage: .generatingNotes,
            completed: 80,
            total: 841
        )
        status.set(.building(progress: generated))

        status.update(.init(stage: .generatingNotes, completed: 40, total: 841))
        XCTAssertEqual(status.state, .building(progress: generated))

        let validating = VoiceRoutingCompilationProgress(
            stage: .validatingPhraseChecks,
            completed: 120,
            total: 4_205
        )
        status.update(validating)
        XCTAssertEqual(status.state, .building(progress: validating))

        status.update(.init(stage: .generatingNotes, completed: 841, total: 841))
        XCTAssertEqual(status.state, .building(progress: validating))
        status.update(.init(stage: .validatingPhraseChecks, completed: 60, total: 4_205))
        XCTAssertEqual(status.state, .building(progress: validating))
    }

    @MainActor
    func testCompletingTheBuildPublishesOneHundredPercentBeforeReady() {
        let status = VoiceRoutingStatus()
        status.set(.building(progress: .init(
            stage: .generatingNotes,
            completed: 3,
            total: 8
        )))

        status.completeBuildingProgress()

        XCTAssertEqual(status.state.compilationProgress?.overallFraction, 1)
        XCTAssertEqual(status.state.compilationProgress?.percentageLabel, "100%")
        XCTAssertTrue(status.state.isWorking)
    }
}
