import Foundation

final class AppServerClient {
    typealias JSON = [String: Any]
    typealias Completion = (Result<JSON, Error>) -> Void

    enum ClientError: LocalizedError {
        case unavailable(String)
        case invalidResponse
        var errorDescription: String? {
            switch self {
            case .unavailable(let message): return message
            case .invalidResponse: return "Codex App Server returned an invalid response"
            }
        }
    }

    private let queue = DispatchQueue(label: "ducky.access.app-server")
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: Completion] = [:]
    private var pendingOnQueue = Set<Int>()
    private var pendingTurns: [String: Completion] = [:]
    private var messageDeltas: [String: String] = [:]

    private(set) var ready = false
    var onReady: (() -> Void)?
    var onUsage: (([UsageWindow]) -> Void)?
    var onModels: (([String]) -> Void)?
    var onError: ((String) -> Void)?

    func start() {
        queue.async { [weak self] in self?.launch() }
    }

    func stop() {
        queue.async { [weak self] in
            self?.output?.readabilityHandler = nil
            self?.process?.terminate()
            self?.process = nil
            self?.input = nil
            self?.output = nil
            self?.ready = false
        }
    }

    func format(_ text: String, model: String, effort: String, serviceTier: String, completion: @escaping (Result<String, Error>) -> Void) {
        let prompt = """
        You are the private text formatter for a macOS dictation tool. Return JSON only in this exact shape: {"text":"..."}.
        Lightly clean the dictated English text: punctuation, capitalization, spoken corrections, bullets, numbered lists, and paragraph breaks. Preserve the user's meaning and wording. Do not add commentary, facts, links, markdown fences, or an introduction.
        Dictated text:
        \(text)
        """
        runEphemeral(prompt: prompt, model: model, effort: effort, serviceTier: serviceTier) { result in
            switch result {
            case .success(let value):
                if let object = Self.jsonObject(from: value),
                   let formatted = object["text"] as? String,
                   !formatted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    completion(.success(formatted.trimmingCharacters(in: .whitespacesAndNewlines)))
                } else {
                    let fallback = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if fallback.isEmpty { completion(.failure(ClientError.invalidResponse)) }
                    else { completion(.success(fallback)) }
                }
            case .failure(let error): completion(.failure(error))
            }
        }
    }

    func routeCommand(_ text: String, model: String, effort: String, serviceTier: String, completion: @escaping (Result<JSON, Error>) -> Void) {
        let prompt = """
        You are a strict command classifier for a macOS accessibility controller. Return JSON only.
        Allowed actions are: focus_app(target), open_url(url), switch_tab(direction), scroll(direction), or none.
        Never return shell commands, file deletion, purchases, message sending, arbitrary computer control, or any other action. Never invent URLs or app names. If the request is unclear, return {"action":"none","reason":"ambiguous"}.
        Request: \(text)
        """
        runEphemeral(prompt: prompt, model: model, effort: effort, serviceTier: serviceTier) { result in
            switch result {
            case .success(let value):
                guard let object = Self.jsonObject(from: value) else {
                    completion(.failure(ClientError.invalidResponse)); return
                }
                completion(.success(object))
            case .failure(let error): completion(.failure(error))
            }
        }
    }

    func refresh() {
        request(method: "model/list", params: ["includeHidden": false]) { [weak self] result in
            if case .success(let response) = result {
                let models = (response["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
                DispatchQueue.main.async { self?.onModels?(models) }
            }
        }
        request(method: "account/rateLimits/read", params: [:]) { [weak self] result in
            guard case .success(let response) = result else { return }
            let source = (response["rateLimitsByLimitId"] as? [String: Any])?["codex"] as? [String: Any]
                ?? response["rateLimits"] as? [String: Any]
            let windows = ["primary", "secondary"].compactMap { key -> UsageWindow? in
                guard let value = source?[key] as? [String: Any], let used = value["usedPercent"] as? Double else { return nil }
                let reset = (value["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
                let minutes = value["windowDurationMins"] as? Double
                let label = minutes.map { "\(Int($0)) min" } ?? key.capitalized
                return UsageWindow(label: label, usedPercent: used, resetDate: reset)
            }
            DispatchQueue.main.async { self?.onUsage?(windows) }
        }
    }

    private func runEphemeral(prompt: String, model: String, effort: String, serviceTier: String, completion: @escaping (Result<String, Error>) -> Void) {
        let outputSchema: JSON = [
            "type": "object",
            "properties": ["text": ["type": "string"], "action": ["type": "string"], "target": ["type": "string"], "url": ["type": "string"], "direction": ["type": "string"], "name": ["type": "string"], "reason": ["type": "string"]],
            "additionalProperties": false
        ]
        request(method: "thread/start", params: [
            "ephemeral": true,
            "model": model,
            "serviceTier": serviceTier,
            "approvalPolicy": "never",
            "sandbox": "read-only",
            "environments": []
        ]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let response):
                guard let thread = response["thread"] as? [String: Any], let threadID = thread["id"] as? String else {
                    completion(.failure(ClientError.invalidResponse)); return
                }
                self.request(method: "turn/start", params: [
                    "threadId": threadID,
                    "input": [["type": "text", "text": prompt]],
                    "model": model,
                    "effort": effort,
                    "serviceTierForTurn": serviceTier,
                    "outputSchema": outputSchema,
                    "environments": []
                ], deliverOnQueue: true) { [weak self] turnResult in
                    guard let self else { return }
                    switch turnResult {
                    case .failure(let error): completion(.failure(error))
                    case .success(let turnResponse):
                        guard let turn = turnResponse["turn"] as? [String: Any], let turnID = turn["id"] as? String else {
                            completion(.failure(ClientError.invalidResponse)); return
                        }
                        // `deliverOnQueue` guarantees this callback is already
                        // on the protocol queue. Register before returning so
                        // a fast item/completed notification cannot outrun it.
                        self.pendingTurns[turnID] = { turnResult in
                            switch turnResult {
                            case .failure(let error): completion(.failure(error))
                            case .success(let params):
                                let turn = params["turn"] as? JSON
                                let items = turn?["items"] as? [[String: Any]] ?? []
                                let text = items
                                    .filter { ($0["type"] as? String) == "agentMessage" }
                                    .compactMap { $0["text"] as? String }
                                    .joined(separator: "\n")
                                DispatchQueue.main.async { completion(.success(text)) }
                            }
                        }
                        self.queue.asyncAfter(deadline: .now() + 20) { [weak self] in
                            guard let self,
                                  let timedOut = self.pendingTurns.removeValue(forKey: turnID) else { return }
                            DispatchQueue.main.async {
                                timedOut(.failure(ClientError.unavailable("Codex App Server timed out")))
                            }
                        }
                    }
                }
            }
        }
    }

    private func launch() {
        guard process == nil else { return }
        let executable = "/Applications/ChatGPT.app/Contents/Resources/codex"
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            publishError("Bundled ChatGPT App Server was not found at \(executable)"); return
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = [
            "app-server", "--stdio",
            "-c", "features.shell_tool=false",
            "-c", "features.apps=false",
            "-c", "web_search=disabled",
            "-c", "features.multi_agent=false"
        ]
        let stdin = Pipe()
        let stdout = Pipe()
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.standardError
        do { try child.run() } catch { publishError(error.localizedDescription); return }
        process = child
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.consume(data) }
        }
        request(method: "initialize", params: [
            "clientInfo": ["name": "ducky-access", "title": "Ducky Access", "version": "0.1.0"],
            "capabilities": ["experimentalApi": true, "requestAttestation": false, "optOutNotificationMethods": []]
        ]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): self.publishError(error.localizedDescription)
            case .success:
                self.sendNotification(method: "initialized", params: [:])
                self.ready = true
                DispatchQueue.main.async { self.onReady?() }
                self.refresh()
            }
        }
    }

    private func request(method: String, params: JSON, deliverOnQueue: Bool = false, completion: @escaping Completion) {
        queue.async { [weak self] in
            guard let self, self.process != nil else {
                let deliver = { completion(.failure(ClientError.unavailable("Codex App Server is unavailable"))) }
                if deliverOnQueue { deliver() } else { DispatchQueue.main.async(execute: deliver) }
                return
            }
            let id = self.nextID; self.nextID += 1
            self.pending[id] = completion
            if deliverOnQueue { self.pendingOnQueue.insert(id) }
            self.write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        }
    }

    private func sendNotification(method: String, params: JSON) {
        queue.async { [weak self] in self?.write(["jsonrpc": "2.0", "method": method, "params": params]) }
    }

    private func write(_ object: JSON) {
        guard let input, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        try? input.write(contentsOf: data + Data([10]))
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? JSON else { continue }
            if let id = object["id"] as? Int, let completion = pending.removeValue(forKey: id) {
                let deliverOnQueue = pendingOnQueue.remove(id) != nil
                if let error = object["error"] as? JSON {
                    let message = error["message"] as? String ?? "Codex App Server error"
                    let deliver = { completion(.failure(ClientError.unavailable(message))) }
                    if deliverOnQueue { deliver() } else { DispatchQueue.main.async(execute: deliver) }
                } else {
                    let result = object["result"] as? JSON ?? object
                    let deliver = { completion(.success(result)) }
                    if deliverOnQueue { deliver() } else { DispatchQueue.main.async(execute: deliver) }
                }
            } else if object["method"] as? String == "item/agentMessage/delta",
                      let params = object["params"] as? JSON,
                      let turnID = params["turnId"] as? String,
                      pendingTurns[turnID] != nil,
                      let itemID = params["itemId"] as? String,
                      let delta = params["delta"] as? String {
                messageDeltas[itemID, default: ""] += delta
            } else if object["method"] as? String == "turn/completed", let params = object["params"] as? JSON,
                      let turnID = (params["turnId"] as? String) ?? ((params["turn"] as? JSON)?["id"] as? String),
                      pendingTurns[turnID] != nil {
                // Some server versions send turn/completed before
                // item/completed. Keep the request pending when the turn
                // carries no message text yet; the item event can still
                // resolve the accumulated deltas below.
                let items = ((params["turn"] as? JSON)?["items"] as? [[String: Any]]) ?? []
                let hasMessage = items.contains {
                    ($0["type"] as? String) == "agentMessage" &&
                    !(($0["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                guard hasMessage, let completion = pendingTurns.removeValue(forKey: turnID) else { continue }
                DispatchQueue.main.async { completion(.success(params)) }
            } else if object["method"] as? String == "turn/failed",
                      let params = object["params"] as? JSON,
                      let turnID = (params["turnId"] as? String) ?? ((params["turn"] as? JSON)?["id"] as? String),
                      let completion = pendingTurns.removeValue(forKey: turnID) {
                let error = (params["error"] as? JSON)?["message"] as? String ?? "Codex App Server could not finish the request"
                DispatchQueue.main.async { completion(.failure(ClientError.unavailable(error))) }
            } else if object["method"] as? String == "item/completed",
                      let params = object["params"] as? JSON,
                      let turnID = params["turnId"] as? String,
                      let item = params["item"] as? JSON,
                      (item["type"] as? String) == "agentMessage" {
                var resolvedItem = item
                if let itemID = item["id"] as? String,
                   (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
                   let delta = messageDeltas.removeValue(forKey: itemID) {
                    resolvedItem["text"] = delta
                }
                guard let text = resolvedItem["text"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let completion = pendingTurns.removeValue(forKey: turnID) else { continue }
                let response: JSON = ["turn": ["items": [resolvedItem]]]
                DispatchQueue.main.async { completion(.success(response)) }
            }
        }
    }

    private func publishError(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onError?(message) }
    }

    private static func jsonObject(from value: String) -> JSON? {
        guard let data = value.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? JSON else { return nil }
        return object
    }
}
