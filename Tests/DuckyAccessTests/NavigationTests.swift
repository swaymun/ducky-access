import XCTest
import AppKit
@testable import DuckyAccess

final class NavigationTests: XCTestCase {
    private let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testCoordinatesOnEveryDisplayArrangementUsePrimaryOrigin() throws {
        let displays = [laptop, CGRect(x: 1512, y: -240, width: 3440, height: 1440),
                        CGRect(x: -3440, y: 120, width: 3440, height: 1440),
                        CGRect(x: 0, y: 982, width: 3440, height: 1440),
                        CGRect(x: 100, y: -1440, width: 3440, height: 1440)]
        for screen in displays {
            let global = CGRect(x: screen.minX + 80, y: screen.minY + 120, width: 160, height: 30)
            let ax = NavigationGeometry.axRect(fromAppKit: global, primaryTop: laptop.maxY)
            XCTAssertEqual(NavigationGeometry.localRect(ax, screen: screen, primaryTop: laptop.maxY), CGRect(x: 80, y: 120, width: 160, height: 30))
        }
    }

    func testSpanningControlsAreClippedToEachDisplayAndLabelsStayInside() {
        let external = CGRect(x: 1512, y: 0, width: 3440, height: 1440)
        let ax = NavigationGeometry.axRect(fromAppKit: CGRect(x: 1492, y: 50, width: 60, height: 30), primaryTop: laptop.maxY)
        XCTAssertEqual(NavigationGeometry.localRect(ax, screen: laptop, primaryTop: laptop.maxY), CGRect(x: 1492, y: 50, width: 20, height: 30))
        XCTAssertEqual(NavigationGeometry.localRect(ax, screen: external, primaryTop: laptop.maxY), CGRect(x: 0, y: 50, width: 40, height: 30))
        XCTAssertNil(NavigationGeometry.localRect(CGRect(x: -9999, y: 0, width: 30, height: 30), screen: laptop, primaryTop: laptop.maxY))
        for frame in [CGRect(x: 1510, y: 0, width: 10, height: 6), CGRect(x: -5, y: 981, width: 10, height: 10)] {
            XCTAssertTrue(laptop.contains(NavigationGeometry.labelRect(for: frame, in: laptop)))
        }
    }

    func testHiddenOffscreenDisabledAndOtherWindowControlsAreExcluded() {
        let fixture = Tree()
        let visible = fixture.node(role: "AXButton", frame: CGRect(x: 20, y: 20, width: 50, height: 20))
        let offscreen = fixture.node(role: "AXButton", frame: CGRect(x: 1500, y: 20, width: 50, height: 20))
        let hiddenChild = fixture.node(role: "AXButton")
        let hiddenGroup = fixture.node(role: "AXGroup", hidden: true, children: [hiddenChild.element])
        let disabled = fixture.node(role: "AXButton", enabled: false)
        _ = fixture.node(role: "AXWindow", children: [fixture.node(role: "AXButton").element])
        let root = fixture.node(role: "AXWindow", children: [visible.element, offscreen.element, hiddenGroup.element, disabled.element])
        let result = NavigationScanner.collect(root: root, screens: [root.frame!], ticket: NavigationTicket(), readNode: fixture.read)
        XCTAssertEqual(result.hints.count, 1)
        XCTAssertTrue(CFEqual(result.hints[0].element, visible.element))
        XCTAssertFalse(fixture.reads.contains { CFEqual($0, hiddenChild.element) })
    }

    func testNestedScrollViewportClipsContentAndExcludesBelowFold() {
        let fixture = Tree()
        let partlyVisible = fixture.node(role: "AXLink", frame: CGRect(x: 110, y: 185, width: 90, height: 30))
        let belowFold = fixture.node(role: "AXLink", frame: CGRect(x: 110, y: 230, width: 90, height: 20))
        let web = fixture.node(role: "AXWebArea", frame: CGRect(x: 100, y: 100, width: 300, height: 3000), children: [partlyVisible.element, belowFold.element])
        let scroll = fixture.node(role: "AXScrollArea", frame: CGRect(x: 100, y: 100, width: 300, height: 100), children: [web.element])
        let root = fixture.node(role: "AXWindow", children: [scroll.element])
        let result = NavigationScanner.collect(root: root, screens: [root.frame!], ticket: NavigationTicket(), readNode: fixture.read)
        XCTAssertEqual(result.hints.map(\.frame), [CGRect(x: 110, y: 185, width: 90, height: 15)])
    }

    func testHintLimitStopsTraversalBeforeReadingWholeTree() {
        let fixture = Tree()
        let children = (0..<500).map { _ in fixture.node(role: "AXButton").element }
        let root = fixture.node(role: "AXWindow", children: children)
        let result = NavigationScanner.collect(root: root, screens: [root.frame!], ticket: NavigationTicket(), readNode: fixture.read)
        XCTAssertEqual(result.hints.count, 225)
        XCTAssertEqual(result.hints.first?.code, "AA")
        XCTAssertEqual(result.hints.last?.code, "OO")
        XCTAssertEqual(fixture.reads.count, 225)
        XCTAssertTrue(result.limited)
    }

    func testNodeDeadlineAndCycleBudgets() {
        let fixture = Tree()
        let child = fixture.node(role: "AXButton")
        let root = fixture.node(role: "AXWindow", children: [child.element, child.element])
        let unique = NavigationScanner.collect(root: root, screens: [root.frame!], ticket: NavigationTicket(), readNode: fixture.read)
        XCTAssertEqual(unique.hints.count, 1)
        let capped = NavigationScanner.collect(root: root, screens: [root.frame!], ticket: NavigationTicket(), maxNodes: 1, readNode: fixture.read)
        XCTAssertEqual(capped.visited, 1)
        XCTAssertTrue(capped.limited)
        let expired = NavigationScanner.collect(root: root, screens: [root.frame!], ticket: NavigationTicket(), seconds: 0, readNode: fixture.read)
        XCTAssertEqual(expired.visited, 0)
        XCTAssertTrue(expired.limited)
        fixture.nodes[CFHash(child.element)] = NavigationNode(element: child.element, role: "AXGroup", frame: child.frame, hidden: false, enabled: true, label: "", children: [root.element], document: "")
        let cyclic = NavigationScanner.collect(root: root, screens: [root.frame!], ticket: NavigationTicket(), readNode: fixture.read)
        XCTAssertEqual(cyclic.visited, 2)
    }

    func testCancellationDuringReadDiscardsPartialHints() {
        let fixture = Tree()
        let root = fixture.node(role: "AXWindow", children: (0..<5).map { _ in fixture.node(role: "AXButton").element })
        let ticket = NavigationTicket()
        let result = NavigationScanner.collect(root: root, screens: [root.frame!], ticket: ticket) { element in
            if fixture.reads.count == 2 { ticket.cancel() }
            return fixture.read(element)
        }
        XCTAssertTrue(result.hints.isEmpty)
        XCTAssertEqual(fixture.reads.count, 3)
    }

    func testLateWorkCannotResurrectClosedOrReopenedGeneration() {
        let lifetime = NavigationLifetime()
        let old = lifetime.current
        lifetime.invalidate()
        let reopened = lifetime.current
        XCTAssertFalse(old.active)
        XCTAssertFalse(lifetime.accepts(old))
        XCTAssertTrue(lifetime.accepts(reopened))
        lifetime.invalidate()
        XCTAssertFalse(lifetime.accepts(reopened))
        var sent = false
        let result = reopened.performIfActive { sent = true; return 1 }
        XCTAssertNil(result)
        XCTAssertFalse(sent)
    }

    func testSnapshotsNoticeChangedTabDocumentElementAndGeometry() {
        let fixture = Tree()
        let root = fixture.node(role: "AXWindow")
        let element = fixture.node(role: "AXButton")
        func snapshot(document: String = "first", frame: CGRect? = nil, target: AXUIElement? = nil, screens: [CGRect]? = nil) -> NavigationSnapshot {
            NavigationSnapshot(pid: 10, window: root.element, frame: root.frame!, document: document, webAreas: [],
                hints: [.init(code: "AA", frame: frame ?? element.frame!, element: target ?? element.element, label: "Test")], visited: 2, limited: false, screens: screens ?? [root.frame!])
        }
        XCTAssertTrue(snapshot().matches(snapshot()))
        XCTAssertFalse(snapshot().matches(snapshot(document: "second")))
        XCTAssertFalse(snapshot().matches(snapshot(frame: CGRect(x: 15, y: 15, width: 30, height: 30))))
        XCTAssertFalse(snapshot().matches(snapshot(target: fixture.node(role: "AXButton").element)))
        XCTAssertFalse(snapshot().matches(snapshot(screens: [CGRect(x: -3440, y: 0, width: 3440, height: 1440)])))
    }

    func testUnsupportedActionsInvalidFramesAndDepthAreBounded() {
        let fixture = Tree()
        var unsupported = fixture.node(role: "AXSlider")
        unsupported.supportsAction = false
        fixture.nodes[CFHash(unsupported.element)] = unsupported
        let invalid = fixture.node(role: "AXButton", frame: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 20))
        XCTAssertFalse(NavigationGeometry.usable(invalid.frame!))
        XCTAssertFalse(NavigationGeometry.usable(CGRect(x: CGFloat.nan, y: 0, width: 30, height: 20)))
        var deep = fixture.node(role: "AXButton")
        for _ in 0..<70 { deep = fixture.node(role: "AXGroup", children: [deep.element]) }
        let root = fixture.node(role: "AXWindow", children: [unsupported.element, deep.element])
        let result = NavigationScanner.collect(root: root, screens: [root.frame!], ticket: NavigationTicket(), readNode: fixture.read)
        XCTAssertTrue(result.hints.isEmpty)
        XCTAssertTrue(result.limited)
        XCTAssertLessThan(result.visited, 70)
    }

    func testChangedWebAreaInvalidatesContextEvenWithoutWindowDocument() {
        let fixture = Tree()
        let root = fixture.node(role: "AXWindow"), first = fixture.node(role: "AXWebArea"), second = fixture.node(role: "AXWebArea")
        func snapshot(_ area: AXUIElement, _ url: String) -> NavigationSnapshot {
            NavigationSnapshot(pid: 10, window: root.element, frame: root.frame!, document: "", webAreas: [(area, url)], hints: [], visited: 2, limited: false, screens: [root.frame!])
        }
        XCTAssertFalse(snapshot(first.element, "first").hasSameContext(as: snapshot(first.element, "second")))
        XCTAssertFalse(snapshot(first.element, "same").hasSameContext(as: snapshot(second.element, "same")))
        XCTAssertTrue(snapshot(first.element, "same").hasSameContext(as: snapshot(first.element, "same")))
    }

    func testSlowScansDropFallbackTicksAndCoalesceInputRefreshes() {
        var schedule = NavigationScanSchedule()
        XCTAssertTrue(schedule.begin(fallback: false))
        for _ in 0..<100 { XCTAssertFalse(schedule.begin(fallback: true)) }
        XCTAssertFalse(schedule.finish())
        XCTAssertTrue(schedule.begin(fallback: false))
        for _ in 0..<100 { XCTAssertFalse(schedule.begin(fallback: false)) }
        XCTAssertTrue(schedule.finish())
        XCTAssertTrue(schedule.begin(fallback: false))
        XCTAssertFalse(schedule.begin(fallback: false))
        schedule.cancelPending()
        XCTAssertFalse(schedule.finish())
    }

    func testElectronAttemptsAreBoundedAndPIDReuseResetsThem() {
        var policy = NavigationElectronOptIn()
        let launched = Date(timeIntervalSince1970: 100)
        for _ in 0..<3 { XCTAssertTrue(policy.shouldAttempt(pid: 42, launchDate: launched)) }
        XCTAssertFalse(policy.shouldAttempt(pid: 42, launchDate: launched))
        XCTAssertTrue(policy.shouldAttempt(pid: 42, launchDate: launched.addingTimeInterval(10)))
        policy.succeeded(pid: 42)
        XCTAssertFalse(policy.shouldAttempt(pid: 42, launchDate: launched.addingTimeInterval(10)))
    }

    private final class Tree {
        var nodes: [CFHashCode: NavigationNode] = [:]
        var reads: [AXUIElement] = []
        private var next: pid_t = 10000
        func node(role: String, frame: CGRect? = CGRect(x: 0, y: 0, width: 1000, height: 800), hidden: Bool = false,
                  enabled: Bool = true, children: [AXUIElement] = []) -> NavigationNode {
            next += 1
            let element = AXUIElementCreateApplication(next) // No AX requests or UI actions.
            let node = NavigationNode(element: element, role: role, frame: frame, hidden: hidden, enabled: enabled, label: role, children: children, document: "")
            nodes[CFHash(element)] = node
            return node
        }
        func read(_ element: AXUIElement) -> NavigationNode? { reads.append(element); return nodes[CFHash(element)] }
    }
}
