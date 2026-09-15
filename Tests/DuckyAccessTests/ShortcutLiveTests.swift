import XCTest
@testable import DuckyAccess

final class ShortcutLiveTests: XCTestCase {
    /// Real Luna routing, synthetic executor: spends model quota but never
    /// opens apps, sends keys, reads personal content, or changes browser tabs.
    func testLiveShortcutRouting() throws {
        guard ProcessInfo.processInfo.environment["DUCKY_TEST_APP_SERVER"] == "1" else { throw XCTSkip("Opt-in App Server routing smoke test.") }
        for (request, expected) in [
            ("In Chrome, open a new tab and go to https://example.com", ["chrome.new_tab", "chrome.navigate"]),
            ("In Codex, create a new chat then open the model picker", ["codex.new_chat", "codex.model_picker"]),
            ("In Chrome, find the video called We drafted the best NBA performances and start playing it", [])
        ] {
            let executor = RecordingExecutor(), computer = NoComputer()
            let session = CommandSession(computer: computer, permissionProfile: .fullAccess, routeShortcuts: true, shortcutExecutor: executor)
            let finished = expectation(description: request)
            let start = Date()
            session.onApproval = { _, reply in reply(false); XCTFail("Unexpected confirmation for routine test request") }
            session.onProgress = { text in
                if expected.isEmpty && text.hasPrefix("Computer use ·") { session.cancel() }
            }
            session.onFinish = { outcome in
                XCTAssertNil(outcome.error, outcome.text)
                XCTAssertEqual(outcome.cancelled, expected.isEmpty)
                XCTAssertEqual(executor.actions, expected)
                XCTAssertEqual(computer.actions, 0)
                print("Routing smoke: \(expected.isEmpty ? "computer fallback" : expected.joined(separator: ",")) in \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
                finished.fulfill()
            }
            session.start(request, model: "gpt-5.6-luna", effort: "low", serviceTier: "priority")
            wait(for: [finished], timeout: 55)
            session.cancel()
        }
    }
}

private final class RecordingExecutor: ShortcutExecuting {
    var actions: [String] = []
    func run(_ plan: ShortcutPlan, initialPID: pid_t?, progress: @escaping (String) -> Void, completion: @escaping (Result<String, Error>) -> Void) {
        actions = plan.steps.map(\.action)
        completion(.success("Synthetic execution only"))
    }
    func cancel() {}
}

private final class NoComputer: CommandRPC {
    var onRequest: (([String: Any]) -> Void)?
    var onNotification: (([String: Any]) -> Void)?
    var onExit: (() -> Void)?
    var actions = 0
    func start(executable: String, arguments: [String]) throws {}
    func send(_ message: [String: Any]) {}
    func stop() {}
    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval, reply: @escaping (Result<[String: Any], Error>) -> Void) {
        if method == "initialize" { reply(.success([:])) }
        else if method == "tools/list" { reply(.success(["tools": NativeComputerControl.specs])) }
        else { actions += 1; reply(.failure(ShortcutPlan.Fault("UI is disabled in this test."))) }
    }
}
