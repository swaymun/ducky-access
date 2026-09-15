import XCTest
@testable import DuckyAccess

final class ShortcutRoutingTests: XCTestCase {
    typealias JSON = [String: Any]

    func testShortcutPlanStrictValidation() throws {
        let request = "In Chrome, open a new tab, go to https://example.com/docs, and find Release Notes"
        let valid = try ShortcutPlan.decode(planJSON(route: "shortcuts", reason: "Use Chrome shortcuts.", steps: [
            ["action": "chrome.new_tab", "argument": NSNull()],
            ["action": "chrome.navigate", "argument": "https://example.com/docs"],
            ["action": "chrome.find", "argument": "Release Notes"]
        ]), request: request)
        XCTAssertEqual(valid.route, .shortcuts)
        XCTAssertEqual(valid.steps.map(\.action), ["chrome.new_tab", "chrome.navigate", "chrome.find"])

        let spokenURL = try ShortcutPlan.decode(planJSON(route: "shortcuts", reason: "Use the spoken URL.", steps: [
            ["action": "chrome.navigate", "argument": "https://example.com/Docs"]
        ]), request: "In Chrome go to example dot com slash Docs")
        XCTAssertEqual(spokenURL.steps.first?.argument, "https://example.com/Docs")

        let mismatchedURLs: [(String, String, String)] = [
            ("trusted host embedded in hostile subdomain", "Go to https://example.com.evil.test", "https://example.com"),
            ("trusted host embedded as another host suffix", "Go to https://notexample.com", "https://example.com"),
            ("shorter path than the requested URL", "Go to https://example.com/docs/private", "https://example.com/docs"),
            ("case-mismatched path", "Go to https://example.com/Docs", "https://example.com/docs"),
            ("URL embedded in a query value", "Go to https://redirect.test/?next=https://example.com", "https://example.com"),
            ("newline in the proposed URL", "Go to https://example.com/docs", "https://example.com/\ndocs")
        ]
        for (name, spokenRequest, proposedURL) in mismatchedURLs {
            let json = planJSON(route: "shortcuts", reason: "No.", steps: [["action": "chrome.navigate", "argument": proposedURL]])
            XCTAssertThrowsError(try ShortcutPlan.decode(json, request: spokenRequest), name)
        }

        let thirteenSteps = (0..<13).map { _ in ["action": "chrome.new_tab", "argument": NSNull()] as JSON }
        let invalid: [(String, String)] = [
            ("unknown action", planJSON(route: "shortcuts", reason: "No.", steps: [["action": "chrome.execute", "argument": NSNull()]])),
            ("empty shortcut route", planJSON(route: "shortcuts", reason: "No.", steps: [])),
            ("computer route with a prefix", planJSON(route: "computer", reason: "Needs context.", steps: [["action": "chrome.new_tab", "argument": NSNull()]])),
            ("argument on a fixed action", planJSON(route: "shortcuts", reason: "No.", steps: [["action": "chrome.new_tab", "argument": "surprise"]])),
            ("invented navigation URL", planJSON(route: "shortcuts", reason: "No.", steps: [["action": "chrome.navigate", "argument": "https://not-requested.example"]])),
            ("non-HTTP URL", planJSON(route: "shortcuts", reason: "No.", steps: [["action": "chrome.navigate", "argument": "file:///tmp/test"]])),
            ("invented find text", planJSON(route: "shortcuts", reason: "No.", steps: [["action": "chrome.find", "argument": "not in the spoken request"]])),
            ("too many steps", planJSON(route: "shortcuts", reason: "No.", steps: thirteenSteps)),
            ("too much rationale", planJSON(route: "clarify", reason: String(repeating: "x", count: 801), steps: [])),
            ("extra plan field", "{\"route\":\"clarify\",\"reason\":\"Which app?\",\"requiresConfirmation\":false,\"steps\":[],\"command\":\"unsafe\"}"),
            ("extra step field", "{\"route\":\"shortcuts\",\"reason\":\"No.\",\"requiresConfirmation\":false,\"steps\":[{\"action\":\"chrome.new_tab\",\"argument\":null,\"keycode\":36}]}"),
            ("missing explicit argument", "{\"route\":\"shortcuts\",\"reason\":\"No.\",\"requiresConfirmation\":false,\"steps\":[{\"action\":\"chrome.new_tab\"}]}"),
        ]
        for (name, json) in invalid {
            XCTAssertThrowsError(try ShortcutPlan.decode(json, request: request), name)
        }
    }

    func testCatalogBindingsAndSchemaAreExact() throws {
        let expectedBindings: [String: String] = [
            "chrome.focus": "built-in", "chrome.new_tab": "Command T", "chrome.new_window": "Command N",
            "chrome.close_tab": "Command W", "chrome.reopen_tab": "Command Shift T",
            "chrome.next_tab": "Command Option Right", "chrome.previous_tab": "Command Option Left",
            "chrome.back": "Command Leftbracket", "chrome.forward": "Command Rightbracket",
            "chrome.address": "Command L", "chrome.navigate": "built-in", "chrome.find": "built-in",
            "chrome.find_next": "Command G", "chrome.find_previous": "Command Shift G",
            "chrome.select_all": "Command A", "chrome.copy": "Command C",
            "chrome.downloads": "Command Shift J", "chrome.history": "Command Y",
            "chrome.zoom_in": "Command Shift Equals", "chrome.zoom_out": "Command Minus", "chrome.zoom_reset": "Command 0",
            "codex.focus": "built-in", "codex.new_chat": "Command N", "codex.new_standalone": "Command Option O",
            "codex.next_chat": "Control Tab", "codex.previous_chat": "Control Shift Tab",
            "codex.attention": "Command Option A", "codex.model_picker": "Control Shift M",
            "codex.project_picker": "Command Option Shift O", "codex.sidebar": "Command B",
            "codex.bottom_panel": "Command J", "codex.file_tree": "Command Shift E", "codex.review": "Control Shift G",
            "codex.browser": "Command T", "codex.find": "Command F",
            "codex.select_all": "Command A", "codex.copy": "Command C", "codex.command_menu": "Command Shift P",
            "codex.keyboard_help": "Command Slash", "codex.settings": "Command Comma",
            "codex.back": "Command Leftbracket", "codex.forward": "Command Rightbracket",
            "chrome.tab_1": "Command 1", "chrome.tab_2": "Command 2", "chrome.tab_3": "Command 3",
            "chrome.tab_4": "Command 4", "chrome.tab_5": "Command 5", "chrome.tab_6": "Command 6",
            "chrome.tab_7": "Command 7", "chrome.tab_8": "Command 8", "chrome.last_tab": "Command 9"
        ]
        var catalogBindings: [String: String] = [:]
        for action in ShortcutPlan.catalog {
            XCTAssertNil(catalogBindings.updateValue(action.chord ?? "built-in", forKey: action.id), "Duplicate catalog action: \(action.id)")
        }
        XCTAssertEqual(catalogBindings, expectedBindings)
        XCTAssertEqual(Set(ShortcutPlan.catalog.map(\.id)).count, ShortcutPlan.catalog.count)
        for action in ShortcutPlan.catalog {
            XCTAssertEqual(action.app, action.id.hasPrefix("chrome.") ? "com.google.Chrome" : "com.openai.codex")
            if let chord = action.chord {
                XCTAssertNotNil(NativeComputerControl.shortcut(chord), "Unparseable catalog chord for \(action.id): \(chord)")
            }
        }
        XCTAssertEqual(ShortcutPlan.action("chrome.close_tab")?.confirmation, true)
        XCTAssertEqual(Set(ShortcutPlan.catalog.filter(\.takesArgument).map(\.id)), ["chrome.navigate", "chrome.find"])

        let required = ShortcutPlan.schema["required"] as? [String]
        XCTAssertEqual(Set(required ?? []), ["route", "reason", "requiresConfirmation", "steps"])
        XCTAssertEqual(ShortcutPlan.schema["additionalProperties"] as? Bool, false)
        let properties = try XCTUnwrap(ShortcutPlan.schema["properties"] as? JSON)
        let steps = try XCTUnwrap(properties["steps"] as? JSON)
        let items = try XCTUnwrap(steps["items"] as? JSON)
        XCTAssertEqual(items["additionalProperties"] as? Bool, false)
        XCTAssertEqual(Set(items["required"] as? [String] ?? []), ["action", "argument"])
        let stepProperties = try XCTUnwrap(items["properties"] as? JSON)
        let actionSchema = try XCTUnwrap(stepProperties["action"] as? JSON)
        XCTAssertEqual(Set(actionSchema["enum"] as? [String] ?? []), Set(expectedBindings.keys))
    }

    func testURLSentencePunctuationAndRootSlash() throws {
        for (request, url) in [("Go to https://example.com.", "https://example.com"),
                               ("Go to example dot com", "https://example.com/")] {
            XCTAssertNoThrow(try ShortcutPlan.decode(planJSON(route: "shortcuts", reason: "Navigate", steps: [
                ["action": "chrome.navigate", "argument": url]
            ]), request: request))
        }
    }

    func testInvalidPrefixDuplicateCompletionAndExecutorFailureNeverReplay() throws {
        let invalid = try startPlanner()
        emitPlan(planJSON(route: "shortcuts", reason: "Invalid last step", steps: [
            ["action": "chrome.new_tab", "argument": NSNull()], ["action": "shell.execute", "argument": NSNull()]
        ]), to: invalid)
        XCTAssertTrue(invalid.executor.runs.isEmpty)
        XCTAssertFalse(invalid.session.active)

        let valid = try startPlanner()
        var outcome: CommandSession.Outcome?
        valid.session.onFinish = { outcome = $0 }
        let json = planJSON(route: "shortcuts", reason: "One action", steps: [["action": "chrome.new_tab", "argument": NSNull()]])
        emitPlan(json, to: valid); emitPlan(json, to: valid)
        XCTAssertEqual(valid.executor.runs.count, 1)
        valid.executor.complete(.failure(ShortcutPlan.Fault("Focus changed; stopped.")))
        XCTAssertEqual(outcome?.error, "Focus changed; stopped.")
        XCTAssertEqual(valid.server.requestHistory.filter { $0 == "thread/start" }.count, 1)
        XCTAssertEqual(valid.executor.runs.count, 1)
    }

    func testPlannerIsToolFreeAndUsesStructuredReadOnlyTurn() throws {
        let harness = try startPlanner()
        defer { harness.session.cancel() }

        let thread = harness.plannerThread
        XCTAssertEqual((thread.params["dynamicTools"] as? [JSON])?.count, 0)
        XCTAssertEqual(thread.params["permissions"] as? String, ":read-only")
        XCTAssertEqual(thread.params["approvalPolicy"] as? String, "never")
        XCTAssertEqual(thread.params["developerInstructions"] as? String, ShortcutPlan.instructions)
        XCTAssertNotNil(harness.plannerTurn.params["outputSchema"] as? JSON)
        XCTAssertFalse(harness.computer.requestHistory.contains("tools/call"))
    }

    func testShortcutProposalReachesExecutorInOrderWithoutComputerActions() throws {
        let harness = try startPlanner(request: "In Chrome, open a new tab, go to https://example.com, then find Privacy")
        var outcome: CommandSession.Outcome?
        harness.session.onFinish = { outcome = $0 }

        emitPlan(planJSON(route: "shortcuts", reason: "Use three local Chrome actions.", steps: [
            ["action": "chrome.new_tab", "argument": NSNull()],
            ["action": "chrome.navigate", "argument": "https://example.com"],
            ["action": "chrome.find", "argument": "Privacy"]
        ]), to: harness)

        XCTAssertEqual(harness.executor.runs.count, 1)
        XCTAssertEqual(harness.executor.runs.first?.actions, ["chrome.new_tab", "chrome.navigate", "chrome.find"])
        XCTAssertFalse(harness.computer.requestHistory.contains("tools/call"))
        harness.executor.complete(.success("Sent 3 shortcut actions."))
        XCTAssertEqual(outcome?.text, "Sent 3 shortcut actions.")
        XCTAssertNil(outcome?.error)
    }

    func testComputerFallbackStartsFreshToolThreadWithoutShortcutPrefix() throws {
        let harness = try startPlanner(profile: .askBeforeActions, request: "Click the visible Privacy link in Chrome")
        emitPlan(planJSON(route: "computer", reason: "The visible page must be inspected.", steps: []), to: harness)

        let fallback = try XCTUnwrap(harness.server.take("thread/start"))
        let tools = try XCTUnwrap(fallback.params["dynamicTools"] as? [JSON])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, ["ducky_get_app_state", "ducky_press_key"])
        XCTAssertEqual(fallback.params["permissions"] as? String, CommandPermissionProfile.askBeforeActions.codexPermission)
        XCTAssertTrue((fallback.params["developerInstructions"] as? String)?.contains("ducky_* computer tools") == true)
        XCTAssertEqual(harness.executor.runs.count, 0)
        XCTAssertFalse(harness.computer.requestHistory.contains("tools/call"))
        harness.session.cancel()
    }

    func testClarificationFinishesWithoutExecution() throws {
        let harness = try startPlanner(request: "Control Command Option")
        var outcome: CommandSession.Outcome?
        harness.session.onFinish = { outcome = $0 }
        emitPlan(planJSON(route: "clarify", reason: "Which key should those modifiers accompany?", steps: []), to: harness)

        XCTAssertEqual(outcome?.text, "Which key should those modifiers accompany?")
        XCTAssertEqual(outcome?.cancelled, false)
        XCTAssertEqual(harness.executor.runs.count, 0)
        XCTAssertFalse(harness.computer.requestHistory.contains("tools/call"))
    }

    func testCancelledPlanningIgnoresLatePlannerOutput() throws {
        let harness = try startPlanner()
        var outcomes: [CommandSession.Outcome] = []
        harness.session.onFinish = { outcomes.append($0) }
        harness.session.cancel()

        emitPlan(planJSON(route: "shortcuts", reason: "Late result.", steps: [["action": "chrome.new_tab", "argument": NSNull()]]), to: harness)

        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes.first?.cancelled, true)
        XCTAssertEqual(harness.executor.runs.count, 0)
        XCTAssertFalse(harness.computer.requestHistory.contains("tools/call"))
    }

    func testStalePlannerThreadAndTurnCannotDispatchShortcuts() throws {
        let harness = try startPlanner()
        let plan = planJSON(route: "shortcuts", reason: "Use a local shortcut.",
                            steps: [["action": "chrome.new_tab", "argument": NSNull()]])

        emitPlan(plan, to: harness, threadID: "stale-thread")
        emitPlan(plan, to: harness, turnID: "stale-turn")
        XCTAssertTrue(harness.session.active)
        XCTAssertEqual(harness.executor.runs.count, 0)

        emitPlan(plan, to: harness)
        XCTAssertEqual(harness.executor.runs.count, 1)
        harness.session.cancel()
    }

    func testFullAccessStillAsksForModelSensitivePlanAndDenialCancels() throws {
        let harness = try startPlanner(profile: .fullAccess, request: "In Codex, open settings")
        var approval: ((Bool) -> Void)?
        var prompt = ""
        var outcome: CommandSession.Outcome?
        harness.session.onApproval = { message, reply in prompt = message; approval = reply }
        harness.session.onFinish = { outcome = $0 }
        emitPlan(planJSON(route: "shortcuts", reason: "Open settings.", requiresConfirmation: true,
                          steps: [["action": "codex.settings", "argument": NSNull()]]), to: harness)

        XCTAssertNotNil(approval)
        XCTAssertTrue(prompt.contains("codex.settings"))
        XCTAssertEqual(harness.executor.runs.count, 0)
        approval?(false)
        XCTAssertEqual(outcome?.cancelled, true)
        XCTAssertEqual(harness.executor.runs.count, 0)
        XCTAssertFalse(harness.computer.requestHistory.contains("tools/call"))
    }

    func testCancellingDuringShortcutExecutionCancelsExecutorAndIgnoresLateCompletion() throws {
        let harness = try startPlanner(request: "In Chrome, open a new tab")
        var outcomes: [CommandSession.Outcome] = []
        harness.session.onFinish = { outcomes.append($0) }
        emitPlan(planJSON(route: "shortcuts", reason: "Use a local shortcut.", steps: [["action": "chrome.new_tab", "argument": NSNull()]]), to: harness)
        XCTAssertEqual(harness.executor.runs.count, 1)

        harness.session.cancel()
        XCTAssertEqual(harness.executor.cancelCount, 1)
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes.first?.cancelled, true)
        harness.executor.complete(.success("Late success must be ignored."))
        XCTAssertEqual(outcomes.count, 1)
    }

    private func startPlanner(profile: CommandPermissionProfile = .fullAccess,
                              request: String = "In Chrome, open a new tab") throws -> RoutingHarness {
        let server = RoutingRPC()
        let computer = RoutingRPC()
        let executor = RecordingShortcutExecutor()
        let session = CommandSession(server: server, computer: computer, permissionProfile: profile,
                                     routeShortcuts: true, shortcutExecutor: executor)
        session.start(request, model: "test-model", effort: "low", serviceTier: "priority")

        try XCTUnwrap(computer.take("initialize")).reply(.success([:]))
        let specs: [JSON] = ["get_app_state", "press_key"].map {
            ["name": $0, "description": "test", "inputSchema": ["type": "object", "properties": ["app": ["type": "string"]], "required": ["app"]]]
        }
        try XCTUnwrap(computer.take("tools/list")).reply(.success(["tools": specs]))
        try XCTUnwrap(server.take("initialize")).reply(.success([:]))
        try XCTUnwrap(server.take("config/read")).reply(.success(["config": ["mcp_servers": ["unrelated": ["enabled": true]]]]))
        let plannerThread = try XCTUnwrap(server.take("thread/start"))
        plannerThread.reply(.success(["thread": ["id": "planner-thread"]]))
        let plannerTurn = try XCTUnwrap(server.take("turn/start"))
        plannerTurn.reply(.success(["turn": ["id": "planner-turn"]]))
        return RoutingHarness(session: session, server: server, computer: computer, executor: executor,
                              plannerThread: plannerThread, plannerTurn: plannerTurn)
    }

    private func emitPlan(_ plan: String, to harness: RoutingHarness,
                          threadID: String = "planner-thread", turnID: String = "planner-turn") {
        harness.server.onNotification?([
            "method": "item/completed",
            "params": ["threadId": threadID, "turnId": turnID,
                       "item": ["type": "agentMessage", "text": plan, "phase": "final_answer"]]
        ])
        harness.server.onNotification?([
            "method": "turn/completed",
            "params": ["threadId": threadID, "turnId": turnID,
                       "turn": ["id": turnID, "status": "completed"]]
        ])
    }

    private func planJSON(route: String, reason: String, requiresConfirmation: Bool = false, steps: [JSON]) -> String {
        let object: JSON = ["route": route, "reason": reason, "requiresConfirmation": requiresConfirmation, "steps": steps]
        return String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
    }
}

private struct RoutingHarness {
    let session: CommandSession
    let server: RoutingRPC
    let computer: RoutingRPC
    let executor: RecordingShortcutExecutor
    let plannerThread: RoutingRPC.Call
    let plannerTurn: RoutingRPC.Call
}

private final class RoutingRPC: CommandRPC {
    typealias JSON = [String: Any]
    typealias Reply = (Result<JSON, Error>) -> Void
    struct Call {
        let method: String
        let params: JSON
        let reply: Reply
    }

    var onRequest: ((JSON) -> Void)?
    var onNotification: ((JSON) -> Void)?
    var onExit: (() -> Void)?
    private(set) var calls: [Call] = []
    private(set) var requestHistory: [String] = []
    private(set) var sent: [JSON] = []
    private(set) var stopCount = 0

    func start(executable: String, arguments: [String]) throws {}
    func request(_ method: String, _ params: JSON, timeout: TimeInterval, reply: @escaping Reply) {
        requestHistory.append(method)
        calls.append(Call(method: method, params: params, reply: reply))
    }
    func send(_ message: JSON) { sent.append(message) }
    func stop() { stopCount += 1 }
    func take(_ method: String) -> Call? {
        guard let index = calls.firstIndex(where: { $0.method == method }) else { return nil }
        return calls.remove(at: index)
    }
}

private final class RecordingShortcutExecutor: ShortcutExecuting {
    struct Run {
        let actions: [String]
        let initialPID: pid_t?
    }
    private(set) var runs: [Run] = []
    private(set) var cancelCount = 0
    private var completion: ((Result<String, Error>) -> Void)?

    func run(_ plan: ShortcutPlan, initialPID: pid_t?, progress: @escaping (String) -> Void,
             completion: @escaping (Result<String, Error>) -> Void) {
        runs.append(Run(actions: plan.steps.map(\.action), initialPID: initialPID))
        self.completion = completion
    }

    func cancel() { cancelCount += 1 }
    func complete(_ result: Result<String, Error>) { completion?(result) }
}
