import XCTest
@testable import DuckyAccess

final class CommandSessionTests: XCTestCase {
    typealias JSON = [String: Any]

    /// Opt-in: uses the signed-in ChatGPT App Server and model quota, but a
    /// synthetic computer surface. No real UI actions or personal content.
    func testLiveAppServerDynamicToolRoundTrip() throws {
        guard ProcessInfo.processInfo.environment["DUCKY_TEST_APP_SERVER"] == "1" else { throw XCTSkip("Set DUCKY_TEST_APP_SERVER=1 for the live model smoke test.") }
        let computer = SyntheticComputerRPC()
        let session = CommandSession(computer: computer, permissionProfile: .fullAccess)
        let finished = expectation(description: "Live App Server command completes")
        session.onFinish = { outcome in
            XCTAssertNil(outcome.error, outcome.text)
            XCTAssertFalse(outcome.cancelled)
            XCTAssertEqual(computer.typed, "12")
            XCTAssertGreaterThanOrEqual(computer.reads, 3)
            finished.fulfill()
        }
        session.start("This is an authorized synthetic UI test, not the real desktop. Only use app com.ducky.test.calculator. Read its state, press 1, read its state, press 2, and read once more to verify the display is 12. Do not use other apps or tools. Report the observed result.", model: "gpt-5.6-luna", effort: "low", serviceTier: "priority")
        wait(for: [finished], timeout: 55)
        session.cancel()
    }

    func testStrictDynamicSchemaAndImageConversion() throws {
        let spec = CommandSession.dynamicSpec(name: "ducky_click", tool: ["inputSchema": ["type": "object", "properties": ["app": ["type": "string"], "x": ["type": "number"]], "required": ["app"]]])
        let schema = try XCTUnwrap(spec["inputSchema"] as? JSON)
        XCTAssertEqual(Set(schema["required"] as? [String] ?? []), ["app", "x", CommandSession.summaryKey, CommandSession.approvalKey])
        let props = try XCTUnwrap(schema["properties"] as? [String: JSON])
        XCTAssertNotNil(props["x"]?["anyOf"])
        let result = CommandSession.convertMCPResult(["content": [["type": "text", "text": "snapshot"], ["type": "image", "mimeType": "image/png", "data": "YWJj"]]])
        let items = try XCTUnwrap(result["contentItems"] as? [JSON])
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[1]["imageUrl"] as? String, "data:image/png;base64,YWJj")
    }

    func testCancelBeforeInitializationNeverStartsAgent() {
        let server = FakeRPC(), computer = FakeRPC()
        let run = CommandSession(server: server, computer: computer)
        var finishes = 0
        run.onFinish = { XCTAssertTrue($0.cancelled); finishes += 1 }
        run.start("read Calculator", model: "test", effort: "low", serviceTier: "priority")
        let callback = computer.take("initialize")
        run.cancel()
        callback?(.success([:]))
        XCTAssertFalse(run.active)
        XCTAssertTrue(server.requests.isEmpty)
        XCTAssertTrue(computer.requests.isEmpty)
        XCTAssertEqual(finishes, 1)
        run.cancel()
        XCTAssertEqual(finishes, 1)
    }

    func testCancellationDropsLateToolsAndCompletions() {
        let (run, server, computer) = startedSession()
        var finishes = 0, progress = 0
        run.onProgress = { _ in progress += 1 }
        run.onFinish = { XCTAssertTrue($0.cancelled); finishes += 1 }
        server.onRequest?(call(1, name: "get_app_state"))
        let lateReply = computer.take("tools/call")
        XCTAssertNotNil(lateReply)
        run.cancel()
        let afterCancel = progress
        lateReply?(.success(["content": [["type": "text", "text": "late state"]]]))
        server.onRequest?(call(2, name: "press_key"))
        server.onNotification?(["method": "turn/completed", "params": ["threadId": "thread", "turn": ["id": "turn", "status": "completed"]]])
        XCTAssertEqual(progress, afterCancel)
        XCTAssertEqual(finishes, 1)
        XCTAssertFalse(computer.requests.contains { $0.method == "tools/call" })
        XCTAssertTrue(server.requestHistory.contains("turn/interrupt"))
    }

    func testCancellationDuringProgressDoesNotDispatchTool() {
        let (run, server, computer) = startedSession()
        run.onProgress = { _ in run.cancel() }
        server.onRequest?(call(1, name: "get_app_state"))
        XCTAssertFalse(run.active)
        XCTAssertFalse(computer.requests.contains { $0.method == "tools/call" })
    }

    func testMutationsRequireFreshObservationAndApproval() {
        let (run, server, computer) = startedSession()
        defer { run.cancel() }
        server.onRequest?(call(1, name: "press_key"))
        XCTAssertFalse(computer.requests.contains { $0.method == "tools/call" })
        server.onRequest?(call(2, name: "get_app_state"))
        computer.take("tools/call")?(.success(["content": [["type": "text", "text": "observed app"]]]))
        var approval: ((Bool) -> Void)?
        run.onApproval = { _, reply in approval = reply }
        server.onRequest?(call(3, name: "press_key", approval: true))
        XCTAssertNotNil(approval)
        XCTAssertFalse(computer.requests.contains { $0.method == "tools/call" })
        approval?(true)
        computer.take("tools/call")?(.success([:]))
        server.onRequest?(call(4, name: "press_key"))
        XCTAssertFalse(computer.requests.contains { $0.method == "tools/call" })
    }

    func testCommentaryDoesNotEndCommand() {
        let (run, server, _) = startedSession()
        var result: CommandSession.Outcome?
        run.onFinish = { result = $0 }
        server.onNotification?(["method": "item/completed", "params": ["threadId": "thread", "item": ["type": "agentMessage", "text": "Checking tabs…", "phase": "commentary"]]])
        XCTAssertTrue(run.active)
        XCTAssertNil(result)
        server.onNotification?(["method": "item/completed", "params": ["threadId": "thread", "item": ["type": "agentMessage", "text": "Closed the requested test tabs.", "phase": "final_answer"]]])
        server.onNotification?(["method": "turn/completed", "params": ["threadId": "thread", "turn": ["id": "turn", "status": "completed"]]])
        XCTAssertFalse(run.active)
        XCTAssertEqual(result?.text, "Closed the requested test tabs.")
    }

    func testDeniedApprovalCancelsWithoutSendingAction() {
        let (run, server, computer) = startedSession()
        server.onRequest?(call(1, name: "get_app_state"))
        computer.take("tools/call")?(.success([:]))
        var outcome: CommandSession.Outcome?
        run.onFinish = { outcome = $0 }
        run.onApproval = { _, reply in reply(false) }
        server.onRequest?(call(2, name: "press_key", approval: true))
        XCTAssertEqual(outcome?.cancelled, true)
        XCTAssertFalse(computer.requests.contains { $0.method == "tools/call" })
    }

    func testMissingAppStaleTurnAndConcurrentActionsAreRejected() {
        let (run, server, computer) = startedSession()
        defer { run.cancel() }
        var request = call(1, name: "press_key")
        var params = request["params"] as! JSON
        var args = params["arguments"] as! JSON
        args.removeValue(forKey: "app"); params["arguments"] = args; request["params"] = params
        server.onRequest?(request)
        XCTAssertFalse(computer.requests.contains { $0.method == "tools/call" })
        request = call(2, name: "get_app_state"); params = request["params"] as! JSON
        params["turnId"] = "old-turn"; request["params"] = params
        server.onRequest?(request)
        XCTAssertFalse(computer.requests.contains { $0.method == "tools/call" })
        server.onRequest?(call(3, name: "get_app_state"))
        server.onRequest?(call(4, name: "get_app_state"))
        XCTAssertEqual(computer.requests.filter { $0.method == "tools/call" }.count, 1)
    }

    func testToolTimeoutStopsAndDoesNotRetryPossibleAction() {
        let (run, server, computer) = startedSession()
        server.onRequest?(call(1, name: "get_app_state"))
        computer.take("tools/call")?(.success([:]))
        var outcome: CommandSession.Outcome?
        run.onFinish = { outcome = $0 }
        server.onRequest?(call(2, name: "press_key"))
        computer.take("tools/call")?(.failure(JSONRPCProcess.RPCError("timed out")))
        XCTAssertFalse(run.active)
        XCTAssertTrue(outcome?.error?.contains("last action may have completed") == true)
        server.onRequest?(call(3, name: "press_key"))
        XCTAssertFalse(computer.requests.contains { $0.method == "tools/call" })
    }

    func testStepBudgetStopsBeforeNextCall() {
        let (run, server, computer) = startedSession()
        var outcome: CommandSession.Outcome?
        run.onFinish = { outcome = $0 }
        for id in 1...40 {
            server.onRequest?(call(id, name: "get_app_state"))
            computer.take("tools/call")?(.success([:]))
        }
        XCTAssertTrue(run.active)
        server.onRequest?(call(41, name: "get_app_state"))
        XCTAssertFalse(run.active)
        XCTAssertTrue(outcome?.error?.contains("40 steps") == true)
        XCTAssertFalse(computer.requests.contains { $0.method == "tools/call" })
    }

    func testNativePermissionFailureStopsWithoutRetry() {
        let (run, server, computer) = startedSession()
        var outcome: CommandSession.Outcome?
        run.onFinish = { outcome = $0 }
        server.onRequest?(call(1, name: "get_app_state"))
        computer.take("tools/call")?(.success(["isError": true, "fatal": true, "content": [["type": "text", "text": "Ducky Access needs its own Accessibility permission."]]]))
        XCTAssertFalse(run.active)
        XCTAssertTrue(outcome?.error?.contains("No app action was sent") == true)
        server.onRequest?(call(2, name: "press_key"))
        XCTAssertFalse(computer.requests.contains { $0.method == "tools/call" })
    }

    func testNativeArgumentBoundary() throws {
        XCTAssertNoThrow(try NativeComputerControl.validate("press_key", ["app": "test", "key": "Command T"]))
        XCTAssertNoThrow(try NativeComputerControl.validate("press_key", ["app": "test", "key": "1"]))
        XCTAssertNoThrow(try NativeComputerControl.validate("click", ["app": "test", "index": 3]))
        XCTAssertNoThrow(try NativeComputerControl.validate("click", ["app": "test", "x": 0.2, "y": 0.4]))
        XCTAssertThrowsError(try NativeComputerControl.validate("eval", ["code": "evil() "]))
        XCTAssertThrowsError(try NativeComputerControl.validate("press_key", ["app": "test", "key": "Command T then Command W"]))
        XCTAssertThrowsError(try NativeComputerControl.validate("type_text", ["app": "test", "text": "hello\nsubmit"]))
        XCTAssertThrowsError(try NativeComputerControl.validate("click", ["app": "test", "index": 3, "x": 0.2, "y": 0.4]))
        XCTAssertThrowsError(try NativeComputerControl.validate("click", ["app": "test", "x": 1.2, "y": 0.4]))
        XCTAssertThrowsError(try NativeComputerControl.validate("click", ["app": "test", "index": true]))
        XCTAssertThrowsError(try NativeComputerControl.validate("click", ["app": "test", "index": 1.5]))
        XCTAssertThrowsError(try NativeComputerControl.validate("get_app_state", ["app": "test", "screenshot": "yes"]))
        XCTAssertThrowsError(try NativeComputerControl.validate("get_app_state", ["app": "test", "code": "evil() "]))
    }

    func testNativeCancellationIsPermanentAndDropsRequests() throws {
        let native = NativeComputerControl()
        native.stop()
        try native.start(executable: "", arguments: [])
        native.request("tools/list", [:]) { _ in XCTFail("Cancelled controller must not call back or restart") }
        let gate = NativeComputerControl.CancellationGate()
        XCTAssertTrue(gate.active)
        gate.cancel()
        XCTAssertFalse(gate.active)
        gate.cancel()
        XCTAssertFalse(gate.active)
        var dispatched = false
        XCTAssertThrowsError(try gate.dispatch { dispatched = true })
        XCTAssertFalse(dispatched)
    }

    func testNativeConfirmationCannotBeDisabledForUnknownExecutionHosts() {
        for bundle in ["com.example.CustomTerminal", "com.google.Chrome", "", "com.microsoft.VSCode"] {
            for action in ["click", "press_key", "type_text", "scroll"] {
                XCTAssertTrue(NativeComputerControl.requiresNativeConfirmation(action, bundleID: bundle))
            }
        }
        XCTAssertFalse(NativeComputerControl.requiresNativeConfirmation("press_key", bundleID: "com.apple.calculator"))
        XCTAssertTrue(NativeComputerControl.requiresNativeConfirmation("type_text", bundleID: "com.apple.TextEdit"))
    }

    func testFullAccessKeepsSensitiveApprovalAndUsesNamedProfile() {
        XCTAssertFalse(NativeComputerControl.requiresNativeConfirmation("press_key", bundleID: "com.google.Chrome", profile: .fullAccess))
        let (run, server, computer) = startedSession(profile: .fullAccess)
        defer { run.cancel() }
        server.onRequest?(call(1, name: "get_app_state"))
        computer.take("tools/call")?(.success([:]))
        var requested = false
        run.onApproval = { _, _ in requested = true }
        server.onRequest?(call(2, name: "press_key", approval: true))
        XCTAssertTrue(requested)
        XCTAssertFalse(computer.requests.contains { $0.method == "tools/call" })
    }

    func testPermissionPreferencePersistsAndUnknownValuesFailSafe() throws {
        let name = "DuckyAccessTests.permissions." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(CommandPermissionProfile.load(from: defaults), .askBeforeActions)
        defaults.set(CommandPermissionProfile.fullAccess.rawValue, forKey: CommandPermissionProfile.defaultsKey)
        XCTAssertEqual(CommandPermissionProfile.load(from: defaults), .fullAccess)
        defaults.set("unknown", forKey: CommandPermissionProfile.defaultsKey)
        XCTAssertEqual(CommandPermissionProfile.load(from: defaults), .askBeforeActions)
    }

    private func startedSession(profile: CommandPermissionProfile = .askBeforeActions) -> (CommandSession, FakeRPC, FakeRPC) {
        let server = FakeRPC(), computer = FakeRPC()
        let run = CommandSession(server: server, computer: computer, permissionProfile: profile)
        run.start("do two steps", model: "test", effort: "low", serviceTier: "priority")
        computer.take("initialize")?(.success([:]))
        let specs: [JSON] = ["get_app_state", "press_key"].map { ["name": $0, "description": "test", "inputSchema": ["type": "object", "properties": ["app": ["type": "string"]], "required": ["app"]]] }
        computer.take("tools/list")?(.success(["tools": specs]))
        server.take("initialize")?(.success([:]))
        server.take("config/read")?(.success(["config": ["mcp_servers": ["unrelated": ["enabled": true]]]]))
        let threadParams = server.requests.first { $0.method == "thread/start" }?.params
        XCTAssertEqual(threadParams?["permissions"] as? String, profile.codexPermission)
        XCTAssertNil(threadParams?["sandbox"])
        let overrides = threadParams?["config"] as? JSON
        let disabled = overrides?["mcp_servers"] as? [String: JSON]
        XCTAssertEqual(disabled?["unrelated"]?["enabled"] as? Bool, false)
        server.take("thread/start")?(.success(["thread": ["id": "thread"]]))
        server.take("turn/start")?(.success(["turn": ["id": "turn"]]))
        return (run, server, computer)
    }

    private func call(_ id: Int, name: String, approval: Bool = false) -> JSON {
        ["method": "item/tool/call", "id": id, "params": ["threadId": "thread", "turnId": "turn", "tool": "ducky_" + name,
            "arguments": ["app": "test.app", "key": "super+t", CommandSession.summaryKey: "Test step", CommandSession.approvalKey: approval]]]
    }
}

private final class SyntheticComputerRPC: CommandRPC {
    typealias JSON = [String: Any]
    var onRequest: ((JSON) -> Void)?
    var onNotification: ((JSON) -> Void)?
    var onExit: (() -> Void)?
    var typed = ""
    var reads = 0
    func start(executable: String, arguments: [String]) throws {}
    func send(_ message: JSON) {}
    func stop() {}
    func request(_ method: String, _ params: JSON, timeout: TimeInterval, reply: @escaping (Result<JSON, Error>) -> Void) {
        if method == "initialize" { reply(.success([:])); return }
        if method == "tools/list" {
            reply(.success(["tools": NativeComputerControl.specs.filter { ["get_app_state", "press_key"].contains($0["name"] as? String ?? "") }])); return
        }
        let args = params["arguments"] as? JSON ?? [:]
        guard args["app"] as? String == "com.ducky.test.calculator" else { reply(.failure(JSONRPCProcess.RPCError("Synthetic test app only."))); return }
        if params["name"] as? String == "get_app_state" { reads += 1 }
        else if params["name"] as? String == "press_key", let key = NativeComputerControl.shortcut(args["key"] as? String ?? ""), key.flags.isEmpty, ["1", "2"].contains(key.keyName) { typed += key.keyName }
        else { reply(.failure(JSONRPCProcess.RPCError("Only pressing 1 or 2 is supported by this test surface; received \(args)."))); return }
        reply(.success(["content": [["type": "text", "text": "Synthetic Calculator app com.ducky.test.calculator; display: \(typed.isEmpty ? "0" : typed). Use one key then read again."]]]))
    }
}

private final class FakeRPC: CommandRPC {
    typealias JSON = [String: Any]
    typealias Reply = (Result<JSON, Error>) -> Void
    var onRequest: ((JSON) -> Void)?
    var onNotification: ((JSON) -> Void)?
    var onExit: (() -> Void)?
    var requests: [(method: String, params: JSON, reply: Reply)] = []
    var requestHistory: [String] = []
    var sent: [JSON] = []
    func start(executable: String, arguments: [String]) throws {}
    func request(_ method: String, _ params: JSON, timeout: TimeInterval, reply: @escaping Reply) { requestHistory.append(method); requests.append((method, params, reply)) }
    func send(_ message: JSON) { sent.append(message) }
    func stop() { requests.removeAll() }
    func take(_ method: String) -> Reply? {
        guard let index = requests.firstIndex(where: { $0.method == method }) else { return nil }
        return requests.remove(at: index).reply
    }
}
