import XCTest
import MatildeKit

final class SyncOnboardingFlowTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testNewAccountWalksEveryStep() {
        var flow = SyncOnboardingFlow(phase: .signedOut, startedAt: start)
        XCTAssertEqual(flow.step, .intro)
        flow.update(phase: .signedOut, syncing: false, lastSynced: nil)
        XCTAssertEqual(flow.step, .intro, "the intro stays until Continue")
        flow.begin()
        XCTAssertEqual(flow.step, .email)
        flow.update(phase: .awaitingCode(email: "a@b.eu"), syncing: false, lastSynced: nil)
        XCTAssertEqual(flow.step, .code(email: "a@b.eu"))
        flow.update(phase: .checkingKey, syncing: false, lastSynced: nil)
        XCTAssertEqual(flow.step, .signingIn)
        XCTAssertTrue(flow.isWorking)
        flow.update(phase: .showRecoveryKey(code: "MTLD-AAAA"), syncing: false, lastSynced: nil)
        XCTAssertEqual(flow.step, .saveKey(code: "MTLD-AAAA"))
        flow.update(phase: .ready, syncing: true, lastSynced: nil)
        XCTAssertEqual(flow.step, .syncing)
        flow.update(phase: .ready, syncing: false, lastSynced: start.addingTimeInterval(-60))
        XCTAssertEqual(flow.step, .syncing, "a sync from before the flow doesn't count")
        flow.update(phase: .ready, syncing: false, lastSynced: start.addingTimeInterval(5))
        XCTAssertEqual(flow.step, .done)
        XCTAssertEqual(flow.progress, 1)
        flow.update(phase: .ready, syncing: true, lastSynced: start.addingTimeInterval(5))
        XCTAssertEqual(flow.step, .done, "later syncs don't reopen the progress step")
    }

    func testSecondDeviceAsksForTheKey() {
        var flow = SyncOnboardingFlow(phase: .signedOut, startedAt: start)
        flow.begin()
        flow.update(phase: .awaitingCode(email: "a@b.eu"), syncing: false, lastSynced: nil)
        flow.update(phase: .needsRecoveryKey, syncing: false, lastSynced: nil)
        XCTAssertEqual(flow.step, .enterKey)
        flow.failed()
        XCTAssertEqual(flow.failures, 1)
    }

    func testChangeEmailGoesBackAndReopeningResumes() {
        var flow = SyncOnboardingFlow(phase: .signedOut, startedAt: start)
        flow.begin()
        flow.update(phase: .awaitingCode(email: "a@b.eu"), syncing: false, lastSynced: nil)
        flow.failed()
        flow.failed()
        XCTAssertEqual(flow.failures, 2)
        flow.update(phase: .signedOut, syncing: false, lastSynced: nil)
        XCTAssertEqual(flow.step, .email)

        XCTAssertEqual(SyncOnboardingFlow(phase: .needsRecoveryKey).step, .enterKey)
        XCTAssertEqual(SyncOnboardingFlow(phase: .updateRequired).step, .updateRequired)
        XCTAssertEqual(SyncOnboardingFlow(phase: .ready, startedAt: start).step, .syncing)
    }

    func testFailuresOnlyCountWhereSomethingWasTyped() {
        var flow = SyncOnboardingFlow(phase: .signedOut, startedAt: start)
        flow.failed()
        XCTAssertEqual(flow.failures, 0)
    }
}

final class OnboardingInputTests: XCTestCase {
    func testEmail() {
        XCTAssertTrue(EmailInput.isPlausible(" Filip@Example.EU "))
        XCTAssertEqual(EmailInput.normalized(" Filip@Example.EU "), "filip@example.eu")
        for bad in ["", "filip", "filip@", "@example.eu", "filip@example", "fi lip@example.eu", "a@b@c.eu", "a@b..eu"] {
            XCTAssertFalse(EmailInput.isPlausible(bad), bad)
        }
    }

    func testOneTimeCode() {
        XCTAssertEqual(OneTimeCodeInput.sanitize("123 456"), "123456")
        XCTAssertEqual(OneTimeCodeInput.sanitize("Your code: 123-456."), "123456")
        XCTAssertEqual(OneTimeCodeInput.sanitize("1234567"), "123456")
        XCTAssertEqual(OneTimeCodeInput.sanitize("１２３"), "123", "full-width digits")
        XCTAssertFalse(OneTimeCodeInput.isComplete("12345"))
        XCTAssertTrue(OneTimeCodeInput.isComplete("12345 6"))
        XCTAssertEqual(OneTimeCodeInput.boxes("12"), ["1", "2", nil, nil, nil, nil])
        XCTAssertEqual(OneTimeCodeInput.activeBox(""), 0)
        XCTAssertEqual(OneTimeCodeInput.activeBox("12"), 2)
        XCTAssertEqual(OneTimeCodeInput.activeBox("123456"), 5)
    }

    func testResendCooldown() {
        let sent = Date(timeIntervalSince1970: 0)
        var cooldown = ResendCooldown(sentAt: sent)
        XCTAssertEqual(cooldown.remaining(at: sent), 30)
        XCTAssertEqual(cooldown.remaining(at: sent.addingTimeInterval(29.2)), 1)
        XCTAssertTrue(cooldown.canResend(at: sent.addingTimeInterval(30)))
        cooldown.restart(at: sent.addingTimeInterval(40))
        XCTAssertFalse(cooldown.canResend(at: sent.addingTimeInterval(41)))
    }

    func testRecoveryKeyAcceptsAnyPasteForm() throws {
        let key = SyncRecoveryKey.generate()
        let code = key.code
        let bare = String(code.dropFirst(5)).replacingOccurrences(of: "-", with: "")
        XCTAssertEqual(RecoveryKeyInput.state(of: code), .valid)
        XCTAssertEqual(RecoveryKeyInput.state(of: bare), .valid)
        XCTAssertEqual(RecoveryKeyInput.state(of: bare.lowercased()), .valid)
        let spaced = RecoveryKeyInput.groups(bare).joined(separator: " ")
        XCTAssertEqual(RecoveryKeyInput.state(of: "  " + spaced + "\n"), .valid)
        XCTAssertEqual(RecoveryKeyInput.normalize(code), bare)
        XCTAssertEqual(RecoveryKeyInput.formatted(code), RecoveryKeyInput.groups(bare).joined(separator: "-"))
        XCTAssertEqual(RecoveryKeyInput.groups(code).count, 13)
    }

    func testRecoveryKeyStates() {
        let bare = String(SyncRecoveryKey.generate().code.dropFirst(5)).replacingOccurrences(of: "-", with: "")
        XCTAssertEqual(RecoveryKeyInput.state(of: ""), .empty)
        XCTAssertEqual(RecoveryKeyInput.state(of: "MTLD-"), .empty)
        XCTAssertEqual(RecoveryKeyInput.state(of: String(bare.prefix(10))), .incomplete(remaining: 42))
        XCTAssertEqual(RecoveryKeyInput.state(of: "ABCU"), .invalidCharacter("U"))
        XCTAssertEqual(RecoveryKeyInput.state(of: bare + "A"), .tooLong)
        // Change one character to another valid one: the check bits catch it (almost always;
        // pick a position in the key bytes and a different value).
        var characters = Array(bare)
        characters[3] = characters[3] == "A" ? "B" : "A"
        let changed = String(characters)
        let state = RecoveryKeyInput.state(of: changed)
        XCTAssertTrue(state == .typo || state == .valid)
        XCTAssertNotNil(RecoveryKeyInput.message(for: .typo))
        XCTAssertNil(RecoveryKeyInput.message(for: .incomplete(remaining: 3)))
        XCTAssertEqual(RecoveryKeyInput.normalize("o i l"), "011")
    }

    func testRecoveryKeyDocument() {
        let text = RecoveryKeyDocument.text(code: "MTLD-AAAA", email: "a@b.eu", date: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(text.contains("MTLD-AAAA"))
        XCTAssertTrue(text.contains("a@b.eu"))
    }
}

final class FirstRunAndSearchTests: XCTestCase {
    func testTourOrder() {
        var tour = FirstRunTour()
        XCTAssertEqual(tour.screen, .welcome)
        XCTAssertNil(tour.carouselIndex)
        tour.next(); XCTAssertEqual(tour.screen, .page(0))
        tour.next(); tour.next(); XCTAssertEqual(tour.screen, .page(2))
        tour.next(); XCTAssertEqual(tour.screen, .finish)
        XCTAssertEqual(tour.carouselIndex, 3)
        tour.next(); XCTAssertEqual(tour.screen, .finish)
        tour.back(); XCTAssertEqual(tour.screen, .page(2))
        tour.show(carouselIndex: 0); XCTAssertEqual(tour.screen, .page(0))
        tour.back(); XCTAssertEqual(tour.screen, .welcome)
        tour.show(carouselIndex: 9); XCTAssertEqual(tour.screen, .finish)
    }

    func testTourFlag() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "FirstRunTests-\(UUID().uuidString)"))
        XCTAssertTrue(FirstRunTour.shouldShow(defaults))
        FirstRunTour.markSeen(defaults)
        XCTAssertFalse(FirstRunTour.shouldShow(defaults))
        FirstRunTour.reset(defaults)
        XCTAssertTrue(FirstRunTour.shouldShow(defaults))
    }

    func testPullPastThresholdOpensSearch() {
        var search = PullToSearch()
        search.dragged(overscroll: 4)
        XCTAssertEqual(search.reveal, 0)
        search.dragged(overscroll: 40)
        XCTAssertGreaterThan(search.reveal, 0)
        XCTAssertFalse(search.armed)
        search.dragged(overscroll: 80)
        XCTAssertTrue(search.armed)
        XCTAssertEqual(search.armChanges, 1)
        XCTAssertEqual(search.reveal, 1)
        search.dragged(overscroll: 60)
        XCTAssertFalse(search.armed)
        XCTAssertEqual(search.armChanges, 2, "dropping back below fires again")
        search.dragged(overscroll: 90)
        XCTAssertTrue(search.released())
        XCTAssertEqual(search.mode, .searching)
        XCTAssertEqual(search.pull, 0)
        search.dragged(overscroll: 100)
        XCTAssertEqual(search.pull, 0, "pulls are ignored while searching")
    }

    func testShortPullSpringsBackAndClosing() {
        var search = PullToSearch()
        search.dragged(overscroll: 50)
        XCTAssertFalse(search.released())
        XCTAssertEqual(search.mode, .browsing)
        search.open()
        search.keyboardDismissed(query: "draft")
        XCTAssertEqual(search.mode, .searching)
        search.keyboardDismissed(query: "  ")
        XCTAssertEqual(search.mode, .browsing)
        search.open(); search.close()
        XCTAssertEqual(search.mode, .browsing)
    }
}

final class RecoveryKeyBackupTests: XCTestCase {
    func testMemoryBackupKeepsOneKeyPerAccount() {
        let backup = MemoryRecoveryKeyBackup()
        XCTAssertNil(backup.load(userId: "u1"))
        XCTAssertTrue(backup.save(code: "MTLD-AAAA", userId: "u1"))
        backup.save(code: "MTLD-BBBB", userId: "u2")
        XCTAssertEqual(backup.load(userId: "u1"), "MTLD-AAAA")
        backup.save(code: "MTLD-CCCC", userId: "u1")
        XCTAssertEqual(backup.load(userId: "u1"), "MTLD-CCCC")
        backup.remove(userId: "u1")
        XCTAssertNil(backup.load(userId: "u1"))
        XCTAssertEqual(backup.load(userId: "u2"), "MTLD-BBBB")
    }
}

final class OneTimeCodeEditorTests: XCTestCase {
    func testTypingAdvancesAndCompletes() {
        var editor = OneTimeCodeEditor()
        for digit in "12345" { editor.insert(String(digit)) }
        XCTAssertEqual(editor.cursor, 5)
        XCTAssertFalse(editor.isComplete)
        editor.insert("6")
        XCTAssertTrue(editor.isComplete)
        XCTAssertEqual(editor.code, "123456")
        XCTAssertEqual(editor.cursor, 5)
        editor.insert("a")
        XCTAssertEqual(editor.code, "123456")
    }

    func testBackspaceClearsThenStepsBack() {
        var editor = OneTimeCodeEditor("123")
        XCTAssertEqual(editor.cursor, 3)
        editor.deleteBackward()
        XCTAssertEqual(editor.cursor, 2)
        XCTAssertEqual(editor.code, "12")
        var full = OneTimeCodeEditor("123456")
        full.deleteBackward()
        XCTAssertEqual(full.code, "12345")
        XCTAssertEqual(full.cursor, 5)
        var empty = OneTimeCodeEditor()
        empty.deleteBackward()
        XCTAssertEqual(empty.cursor, 0)
    }

    func testArrowsMoveAndTypingReplacesThatBox() {
        var editor = OneTimeCodeEditor("123456")
        editor.moveLeft(); editor.moveLeft()
        XCTAssertEqual(editor.cursor, 3)
        editor.insert("9")
        XCTAssertEqual(editor.code, "123956")
        XCTAssertEqual(editor.cursor, 4)
        for _ in 0..<10 { editor.moveRight() }
        XCTAssertEqual(editor.cursor, 5)
        editor.move(to: -3)
        XCTAssertEqual(editor.cursor, 0)
    }

    func testPasteReplacesFromAnyBox() {
        var editor = OneTimeCodeEditor("98")
        editor.insert(" 123-456 ")
        XCTAssertTrue(editor.isComplete)
        XCTAssertEqual(editor.code, "123456")
        var partial = OneTimeCodeEditor("1")
        partial.insert("2 3")
        XCTAssertEqual(partial.code, "123")
        XCTAssertEqual(partial.cursor, 3)
        partial.clear()
        XCTAssertEqual(partial, OneTimeCodeEditor())
    }
}
