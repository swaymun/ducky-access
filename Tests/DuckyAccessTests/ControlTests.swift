import XCTest
import AppKit
@testable import DuckyAccess

final class ControlTests: XCTestCase {
    func testLiteralShortcuts() {
        for phrase in ["Command T", "command + t.", "Press the cmd and T keys", "comand t", "⌘T"] {
            XCTAssertEqual(SpokenShortcut.parse(phrase), .shortcut(KeyboardShortcut(keyCode: 17, flags: .maskCommand, keyName: "T")), phrase)
        }
        XCTAssertEqual(SpokenShortcut.parse("Control + command + option + T"), .shortcut(KeyboardShortcut(keyCode: 17, flags: [.maskControl, .maskCommand, .maskAlternate], keyName: "T")))
        XCTAssertEqual(SpokenShortcut.parse("command shift tab"), .shortcut(KeyboardShortcut(keyCode: 48, flags: [.maskCommand, .maskShift], keyName: "Tab")))
        XCTAssertEqual(SpokenShortcut.parse("Press Enter"), .shortcut(KeyboardShortcut(keyCode: 36, flags: [], keyName: "Return")))
        XCTAssertEqual(SpokenShortcut.parse("alt left arrow"), .shortcut(KeyboardShortcut(keyCode: 123, flags: .maskAlternate, keyName: "←")))
    }

    func testModifierOnlyAndSequencesNeverExecute() {
        for phrase in ["Ctrl + command + option", "Command", "Command T then Command W", "Control banana", "I said command T", "command t, command w"] {
            guard case .invalid = SpokenShortcut.parse(phrase) else { return XCTFail("Unexpected shortcut: \(phrase)") }
        }
    }

    func testNaturalCommandsFallThrough() {
        for phrase in ["Open Safari", "switch to Chrome", "scroll down", "next tab", "open example.com", ""] {
            XCTAssertEqual(SpokenShortcut.parse(phrase), .notShortcut, phrase)
        }
    }

    func testEnterWaitsForModifierReleaseAndRoutesOnce() {
        let router = KeyboardRouter()
        let routed = expectation(description: "Enter after release")
        routed.assertForOverFulfill = true
        var actions = 0
        router.onAction = { action in
            guard case .enter = action else { return XCTFail("Wrong action") }
            actions += 1
            routed.fulfill()
        }
        let modifiers: CGEventFlags = [.maskControl, .maskShift, .maskAlternate, .maskCommand]
        XCTAssertNil(router.processEvent(.keyDown, event(key: 80, down: true, flags: modifiers)))
        let repeated = event(key: 80, down: true, flags: modifiers)
        repeated.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        XCTAssertNil(router.processEvent(.keyDown, repeated))
        XCTAssertNil(router.processEvent(.keyUp, event(key: 80, down: false, flags: modifiers)))
        XCTAssertEqual(actions, 0)
        _ = router.processEvent(.flagsChanged, event(key: 55, down: false, flags: []))
        _ = router.processEvent(.flagsChanged, event(key: 55, down: false, flags: []))
        wait(for: [routed], timeout: 0.5)
        XCTAssertEqual(actions, 1)
    }

    func testEncoderRoutesBeforeSwitcherFiltersModifierRelease() {
        let router = KeyboardRouter()
        let routed = expectation(description: "knob after release")
        router.onAction = { action in
            guard case .appSwitcher = action else { return XCTFail("Wrong action") }
            routed.fulfill()
        }
        router.filterUnmatchedEvent = { _, _ in nil }
        let modifiers: CGEventFlags = [.maskControl, .maskShift, .maskAlternate]
        XCTAssertNil(router.processEvent(.keyDown, event(key: 113, down: true, flags: modifiers)))
        XCTAssertNil(router.processEvent(.keyUp, event(key: 113, down: false, flags: modifiers)))
        XCTAssertNil(router.processEvent(.flagsChanged, event(key: 59, down: false, flags: [])))
        wait(for: [routed], timeout: 0.5)
    }

    func testGeneratedChordsCannotTriggerPadActions() {
        let router = KeyboardRouter()
        let own = event(key: 80, down: true, flags: [.maskControl, .maskShift, .maskAlternate, .maskCommand])
        own.setIntegerValueField(.eventSourceUserData, value: KeyboardOutput.eventTag)
        XCTAssertNotNil(router.processEvent(.keyDown, own))
        XCTAssertNotNil(router.processEvent(.keyDown, event(key: 17, down: true, flags: .maskCommand)))
    }

    func testGeneratedScrollCannotInvalidateNavigationTwice() throws {
        let router = KeyboardRouter()
        var invalidations = 0
        router.filterUnmatchedEvent = { _, event in invalidations += 1; return event }
        let scroll = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .privateState), units: .line, wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0))
        scroll.setIntegerValueField(.eventSourceUserData, value: KeyboardOutput.eventTag)
        XCTAssertNotNil(router.processEvent(.scrollWheel, scroll))
        XCTAssertEqual(invalidations, 0)
        let physical = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .privateState), units: .line, wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0))
        XCTAssertNotEqual(physical.getIntegerValueField(.eventSourceUserData), KeyboardOutput.eventTag)
        XCTAssertNotNil(router.processEvent(.scrollWheel, physical))
        XCTAssertEqual(invalidations, 1)
    }

    private func event(key: CGKeyCode, down: Bool, flags: CGEventFlags) -> CGEvent {
        let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: key, keyDown: down)!
        event.flags = flags
        return event // Tests inspect events; they NEVER post them to macOS.
    }
}
