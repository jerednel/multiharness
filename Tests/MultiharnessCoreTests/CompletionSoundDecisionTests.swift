import XCTest
import MultiharnessCore

final class CompletionSoundDecisionTests: XCTestCase {
    private let workspaceA = UUID()
    private let workspaceB = UUID()

    func testDisabledNeverPlays() {
        XCTAssertFalse(CompletionSoundDecision.shouldPlay(
            enabled: false,
            appIsFrontmost: true,
            selectedWorkspaceId: workspaceA,
            eventWorkspaceId: workspaceA
        ))
        XCTAssertFalse(CompletionSoundDecision.shouldPlay(
            enabled: false,
            appIsFrontmost: false,
            selectedWorkspaceId: nil,
            eventWorkspaceId: workspaceA
        ))
    }

    func testFrontmostAndSameWorkspaceSuppresses() {
        XCTAssertFalse(CompletionSoundDecision.shouldPlay(
            enabled: true,
            appIsFrontmost: true,
            selectedWorkspaceId: workspaceA,
            eventWorkspaceId: workspaceA
        ))
    }

    func testFrontmostButDifferentWorkspacePlays() {
        XCTAssertTrue(CompletionSoundDecision.shouldPlay(
            enabled: true,
            appIsFrontmost: true,
            selectedWorkspaceId: workspaceB,
            eventWorkspaceId: workspaceA
        ))
    }

    func testFrontmostButNoWorkspaceSelectedPlays() {
        XCTAssertTrue(CompletionSoundDecision.shouldPlay(
            enabled: true,
            appIsFrontmost: true,
            selectedWorkspaceId: nil,
            eventWorkspaceId: workspaceA
        ))
    }

    func testBackgroundedPlaysRegardlessOfSelection() {
        XCTAssertTrue(CompletionSoundDecision.shouldPlay(
            enabled: true,
            appIsFrontmost: false,
            selectedWorkspaceId: workspaceA,
            eventWorkspaceId: workspaceA
        ))
        XCTAssertTrue(CompletionSoundDecision.shouldPlay(
            enabled: true,
            appIsFrontmost: false,
            selectedWorkspaceId: nil,
            eventWorkspaceId: workspaceA
        ))
    }
}
