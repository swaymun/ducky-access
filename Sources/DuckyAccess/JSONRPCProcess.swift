import Foundation

protocol CommandRPC: AnyObject {
    var onRequest: (([String: Any]) -> Void)? { get set }
    var onNotification: (([String: Any]) -> Void)? { get set }
    var onExit: (() -> Void)? { get set }
    func start(executable: String, arguments: [String]) throws
    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval, reply: @escaping (Result<[String: Any], Error>) -> Void)
    func send(_ message: [String: Any])
    func stop()
}

extension CommandRPC {
    func request(_ method: String, _ params: [String: Any], reply: @escaping (Result<[String: Any], Error>) -> Void) {
        request(method, params, timeout: 20, reply: reply)
    }
}

/// Main-queue JSONL transport. A session owns its children; cancellation never
/// touches the user's Codex or Computer Use processes.
final class JSONRPCProcess: CommandRPC {
    typealias JSON = [String: Any]
    typealias Reply = (Result<JSON, Error>) -> Void
    var onRequest: ((JSON) -> Void)?
    var onNotification: ((JSON) -> Void)?
    var onExit: (() -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: Reply] = [:]
    private let environment: [String: String]

    init(environment: [String: String] = [:]) { self.environment = environment }

    func start(executable: String, arguments: [String]) throws {
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = arguments
        child.environment = ProcessInfo.processInfo.environment.merging(environment) { _, value in value }
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        try child.run()
        process = child; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async {
                guard let self, self.process != nil else { return }
                if data.isEmpty { self.onExit?() } else { self.consume(data) }
            }
        }
    }

    func request(_ method: String, _ params: JSON, timeout: TimeInterval = 20, reply: @escaping Reply) {
        guard process?.isRunning == true else { reply(.failure(RPCError("Connection is not running."))); return }
        let id = nextID; nextID += 1
        pending[id] = reply
        send(["id": id, "method": method, "params": params])
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.pending.removeValue(forKey: id)?(.failure(RPCError("\(method) timed out.")))
        }
    }

    func send(_ message: JSON) {
        var object = message; object["jsonrpc"] = "2.0"
        guard let input, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        do { try input.write(contentsOf: data + Data([10])) }
        catch { onExit?() }
    }

    func stop() {
        output?.readabilityHandler = nil
        // Close stdin first so a runtime can cancel work and reap its children.
        // Terminate only this owned process if graceful shutdown stalls.
        try? input?.close()
        if let child = process {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if child.isRunning { child.terminate() }
            }
        }
        process = nil; input = nil; output = nil
        pending.removeAll(); buffer.removeAll()
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? JSON else { continue }
            // Server request IDs occupy a different namespace from our IDs.
            if object["method"] != nil {
                if object["id"] != nil { onRequest?(object) } else { onNotification?(object) }
            } else if let id = object["id"] as? Int, let reply = pending.removeValue(forKey: id) {
                if let error = object["error"] as? JSON { reply(.failure(RPCError(error["message"] as? String ?? "Request failed."))) }
                else { reply(.success(object["result"] as? JSON ?? [:])) }
            }
        }
    }

    struct RPCError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
