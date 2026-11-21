import XCTest
@testable import Matilde
import MatildeKit

final class ThreadChatTests: XCTestCase {
    private let viewport: CGFloat = 300

    /// Observes the thread scrolled so that its end sits `distance` points below the viewport.
    private func observe(_ follower: inout BottomFollower, height: CGFloat, distance: CGFloat) {
        follower.observe(contentTop: viewport + distance - height, contentHeight: height, viewportHeight: viewport)
    }

    func testFollowsAtTheEndAndStopsWhenTheReaderScrollsUp() {
        var follower = BottomFollower()
        observe(&follower, height: 800, distance: 0)
        XCTAssertTrue(follower.following)
        observe(&follower, height: 800, distance: BottomFollower.tolerance - 2)
        XCTAssertTrue(follower.following, "A few points from the end still counts as the end")
        observe(&follower, height: 800, distance: 60)
        XCTAssertFalse(follower.following)
        observe(&follower, height: 800, distance: 4)
        XCTAssertTrue(follower.following, "Scrolling back to the end resumes following")
    }

    func testStreamedGrowthNeitherPinsNorUnpins() {
        var follower = BottomFollower()
        observe(&follower, height: 800, distance: 0)
        // A new line arrives while following: the end moves below the viewport until the view follows.
        observe(&follower, height: 820, distance: 20)
        XCTAssertTrue(follower.following)
        observe(&follower, height: 820, distance: 0)
        XCTAssertTrue(follower.following)

        // The reader scrolls up; new lines keep arriving and must not pull the view back.
        observe(&follower, height: 820, distance: 200)
        XCTAssertFalse(follower.following)
        observe(&follower, height: 840, distance: 220)
        observe(&follower, height: 860, distance: 240)
        XCTAssertFalse(follower.following)
    }

    func testScrollingUpWhileALineArrivesStopsFollowing() {
        var follower = BottomFollower()
        observe(&follower, height: 800, distance: 0)
        // Same frame: content grew 20 points and the reader moved 50 points towards the top.
        observe(&follower, height: 820, distance: 70)
        XCTAssertFalse(follower.following)
    }

    func testShortThreadsAlwaysFollowAndSendingJumpsToTheEnd() {
        var follower = BottomFollower()
        observe(&follower, height: 800, distance: 300)
        XCTAssertFalse(follower.following)
        follower.follow()
        // The jump itself (and growth from the sent message) is not read as scrolling up.
        observe(&follower, height: 840, distance: 340)
        observe(&follower, height: 840, distance: 340)
        XCTAssertTrue(follower.following)
        observe(&follower, height: 840, distance: 0)
        observe(&follower, height: 840, distance: 100)
        XCTAssertFalse(follower.following, "After reaching the end, scrolling up stops following again")

        var short = BottomFollower()
        short.observe(contentTop: 0, contentHeight: 200, viewportHeight: viewport)
        XCTAssertTrue(short.following)
    }

    func testAssistantLabelOnlyWhereTheSpeakerChanges() {
        let roles = ["user", "assistant", "assistant", "user", "assistant"]
        XCTAssertEqual(roles.indices.map { ThreadSpeaker.showsAssistantLabel(at: $0, roles: roles) },
                       [false, true, false, false, true])
        XCTAssertTrue(ThreadSpeaker.showsAssistantLabel(at: 0, roles: ["assistant"]))
        XCTAssertFalse(ThreadSpeaker.showsAssistantLabel(at: 3, roles: ["assistant"]))
    }

    func testReturnSendsAndModifiedReturnAddsALine() {
        XCTAssertEqual(ComposerReturn.action(modifiers: [], composing: false), .send)
        XCTAssertEqual(ComposerReturn.action(modifiers: [.command], composing: false), .send)
        XCTAssertEqual(ComposerReturn.action(modifiers: [.capsLock, .numericPad], composing: false), .send, "Unrelated flags still send")
        XCTAssertEqual(ComposerReturn.action(modifiers: [.shift], composing: false), .newline)
        XCTAssertEqual(ComposerReturn.action(modifiers: [.option], composing: false), .newline)
        XCTAssertEqual(ComposerReturn.action(modifiers: [.control], composing: false), .newline)
        XCTAssertEqual(ComposerReturn.action(modifiers: [.shift, .command], composing: false), .newline)
        XCTAssertNil(ComposerReturn.action(modifiers: [], composing: true), "Return confirms an input method's composition")
        XCTAssertNil(ComposerReturn.action(modifiers: [.shift], composing: true))
    }
}
