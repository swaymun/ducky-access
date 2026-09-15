import XCTest
import ApplicationServices
import AppKit
@testable import DuckyAccess

final class NavigationActivationTests: XCTestCase {
    func testPointerActionsInsteadOfAcknowledgedAXRequests() {
        for role in ["AXButton", "AXLink", "AXTab", "AXCell", "AXTextField", "AXTextArea", "AXComboBox", "AXPopUpButton"] {
            XCTAssertFalse(NavigationActivation.usesPress(role: role), role)
        }
        XCTAssertTrue(NavigationActivation.usesPress(role: "AXMenuItem"))
    }

    func testClickUsesVisibleAXCoordinatesIncludingExternalDisplayAndGaps() {
        let screens = [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: -3500, y: -200, width: 3440, height: 1440)]
        XCTAssertEqual(NavigationActivation.clickPoint(frame: CGRect(x: -3000, y: -100, width: 100, height: 40), screens: screens), CGPoint(x: -2950, y: -80))
        // Midpoint (-25, 220) is in the gap, so choose the larger visible portion.
        XCTAssertEqual(NavigationActivation.clickPoint(frame: CGRect(x: -150, y: 200, width: 250, height: 40), screens: screens), CGPoint(x: 50, y: 220))
        XCTAssertNil(NavigationActivation.clickPoint(frame: CGRect(x: -40, y: 0, width: 20, height: 30), screens: screens))
        XCTAssertNil(NavigationActivation.clickPoint(frame: .null, screens: screens))
        XCTAssertNil(NavigationActivation.clickPoint(frame: screens[0], screens: []))
    }

    func testSingleClickPairHasNoModifiersAndCannotInvalidateOwnNAV() throws {
        let point = CGPoint(x: -2000, y: 400)
        let events = try XCTUnwrap(NavigationActivation.clickEvents(at: point, windowNumber: 1234))
        XCTAssertEqual(events.map(\.type), [.leftMouseDown, .leftMouseUp])
        let router = KeyboardRouter()
        var invalidations = 0
        router.filterUnmatchedEvent = { _, event in invalidations += 1; return event }
        for event in events {
            XCTAssertEqual(event.location, point)
            XCTAssertEqual(event.flags, [])
            XCTAssertEqual(event.getIntegerValueField(.mouseEventClickState), 1)
            XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), KeyboardOutput.eventTag)
            XCTAssertEqual(event.getIntegerValueField(.mouseEventWindowUnderMousePointer), 1234)
            XCTAssertEqual(event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent), 1234)
            XCTAssertEqual(NSEvent(cgEvent: event)?.windowNumber, 1234)
            XCTAssertNotNil(router.processEvent(event.type, event))
        }
        XCTAssertEqual(invalidations, 0)
        XCTAssertNil(NavigationActivation.clickEvents(at: CGPoint(x: CGFloat.infinity, y: 0), windowNumber: 1234))
        XCTAssertNil(NavigationActivation.clickEvents(at: point, windowNumber: 0))
        XCTAssertNil(NavigationActivation.clickEvents(at: point, windowNumber: -1))
        XCTAssertNil(NavigationActivation.clickEvents(at: point, windowNumber: Int(UInt32.max) + 1))
    }

    func testHitMustBeTargetOrNonInteractiveDescendantNotNestedControl() {
        let target = AXUIElementCreateApplication(20001)
        let text = AXUIElementCreateApplication(20002)
        let other = AXUIElementCreateApplication(20003)
        let ticket = NavigationTicket()
        XCTAssertTrue(NavigationActivation.hitMatches(target, target: target, ticket: ticket, parent: { _ in nil }, passive: { _ in false }))
        XCTAssertTrue(NavigationActivation.hitMatches(text, target: target, ticket: ticket, parent: { _ in target }, passive: { _ in true }))
        XCTAssertFalse(NavigationActivation.hitMatches(other, target: target, ticket: ticket, parent: { _ in nil }, passive: { _ in true }))
        // A close button inside a tab is NOT permission to close the tab.
        for role in ["AXButton", "AXIncrementor", "AXScrollBar", "AXUnknown"] {
            XCTAssertFalse(NavigationActivation.hitMatches(text, target: target, ticket: ticket, parent: { _ in target }, passive: { _ in NavigationActivation.isPassive(role: role, actions: [], focusable: false) }))
        }
        XCTAssertFalse(NavigationActivation.isPassive(role: "AXGroup", actions: ["AXPress"], focusable: false))
        XCTAssertFalse(NavigationActivation.isPassive(role: "AXGroup", actions: [], focusable: true))
        XCTAssertTrue(NavigationActivation.isPassive(role: "AXStaticText", actions: [], focusable: false))
        XCTAssertTrue(NavigationActivation.isPassive(role: "AXImage", actions: [], focusable: false))
        let chromiumTextActions = ["AXShowMenu", "AXScrollToVisible"]
        XCTAssertTrue(NavigationActivation.hitMatches(text, target: target, ticket: ticket, parent: { _ in target }, passive: { _ in NavigationActivation.isPassive(role: "AXStaticText", actions: chromiumTextActions, focusable: false) }))
        for action in ["AXPress", "AXIncrement", "AXPick", "UnknownCustomAction"] {
            XCTAssertFalse(NavigationActivation.isPassive(role: "AXGroup", actions: chromiumTextActions + [action], focusable: false))
        }
    }

    func testHitWalkStopsOnCancellationCycleAndDepth() {
        let target = AXUIElementCreateApplication(20101)
        let child = AXUIElementCreateApplication(20102)
        let cancelled = NavigationTicket(); cancelled.cancel()
        XCTAssertFalse(NavigationActivation.hitMatches(target, target: target, ticket: cancelled))
        let duringWalk = NavigationTicket()
        XCTAssertFalse(NavigationActivation.hitMatches(child, target: target, ticket: duringWalk, parent: { _ in duringWalk.cancel(); return target }, passive: { _ in true }))
        XCTAssertFalse(NavigationActivation.hitMatches(child, target: target, ticket: NavigationTicket(), parent: { _ in child }, passive: { _ in true }))
        var reads: Int32 = 0
        XCTAssertFalse(NavigationActivation.hitMatches(child, target: target, ticket: NavigationTicket(), parent: { _ in reads += 1; return AXUIElementCreateApplication(20200 + reads) }, passive: { _ in true }))
        XCTAssertEqual(reads, 16)
        var dispatched = 0
        cancelled.performIfActive { dispatched += 1 }
        XCTAssertEqual(dispatched, 0)
    }

    func testHitIsCheckedAfterContextAndChangedTargetPostsNothing() throws {
        let events = try XCTUnwrap(NavigationActivation.clickEvents(at: .zero, windowNumber: 1234))
        var sameTarget = true
        var posts = 0
        XCTAssertFalse(NavigationActivation.dispatchClick(events: events, ticket: NavigationTicket(), validateContext: {
            sameTarget = false // Page reflows while final window/context reads run.
            return true
        }, validateHit: { sameTarget }, post: { _ in posts += 1 }))
        XCTAssertEqual(posts, 0)
        let cancelled = NavigationTicket()
        XCTAssertFalse(NavigationActivation.dispatchClick(events: events, ticket: cancelled, validateContext: { true }, validateHit: {
            cancelled.cancel(); return true
        }, post: { _ in posts += 1 }))
        XCTAssertEqual(posts, 0)
        var order: [String] = []
        XCTAssertTrue(NavigationActivation.dispatchClick(events: events, ticket: NavigationTicket(), validateContext: {
            order.append("context"); return true
        }, validateHit: { order.append("hit"); return true }, post: { event in order.append(event.type == .leftMouseDown ? "down" : "up") }))
        XCTAssertEqual(order, ["context", "hit", "down", "up"])
    }

    func testDestinationWindowMustMatchOwnerGeometryAndVisibility() {
        let rect = CGRect(x: 800, y: -1200, width: 1000, height: 900)
        let point = CGPoint(x: 1000, y: -900)
        let valid: [String: Any] = [kCGWindowNumber as String: 1234, kCGWindowOwnerPID as String: 42,
            kCGWindowIsOnscreen as String: true, kCGWindowBounds as String: rect.dictionaryRepresentation]
        XCTAssertTrue(NavigationActivation.matchesWindow(valid, number: 1234, pid: 42, frame: rect, point: point))
        XCTAssertFalse(NavigationActivation.matchesWindow(valid, number: 1235, pid: 42, frame: rect, point: point))
        XCTAssertFalse(NavigationActivation.matchesWindow(valid, number: 1234, pid: 43, frame: rect, point: point))
        XCTAssertFalse(NavigationActivation.matchesWindow(valid, number: 1234, pid: 42, frame: rect.offsetBy(dx: 5, dy: 0), point: point))
        XCTAssertFalse(NavigationActivation.matchesWindow(valid, number: 1234, pid: 42, frame: rect, point: .zero))
        var hidden = valid; hidden[kCGWindowIsOnscreen as String] = false
        XCTAssertFalse(NavigationActivation.matchesWindow(hidden, number: 1234, pid: 42, frame: rect, point: point))
        XCTAssertFalse(NavigationActivation.matchesWindow([:], number: 1234, pid: 42, frame: rect, point: point))
    }
}
