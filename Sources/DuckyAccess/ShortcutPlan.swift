import Foundation

/// Model output is a proposal, never executable keys or code. The entire plan
/// is validated before the first app activation; unknown work uses computer use.
struct ShortcutPlan: Decodable {
    enum Route: String, Decodable { case shortcuts, computer, clarify }
    struct Step: Decodable, Equatable {
        let action: String
        let argument: String?
    }
    let route: Route
    let reason: String
    let requiresConfirmation: Bool
    let steps: [Step]

    struct Action {
        let id: String
        let title: String
        let chord: String?
        var app: String { id.hasPrefix("chrome.") ? "com.google.Chrome" : "com.openai.codex" }
        var takesArgument: Bool { id == "chrome.navigate" || id == "chrome.find" }
    }

    // Sources: official Chrome Mac shortcuts and OpenAI Commands, checked
    // 2026-09-14. Defaults only; customized bindings may differ. No terminal,
    // console, submit, approval, arbitrary typing, or settings mutation actions.
    static let catalog: [Action] = {
        let chrome: [(String, String, String?)] = [
            ("focus", "Focus Chrome", nil), ("new_tab", "New tab", "Command T"),
            ("new_window", "New window", "Command N"), ("close_tab", "Close current tab", "Command W"),
            ("reopen_tab", "Reopen closed tab", "Command Shift T"),
            ("next_tab", "Next tab", "Command Option Right"), ("previous_tab", "Previous tab", "Command Option Left"),
            ("back", "Back one page", "Command Leftbracket"), ("forward", "Forward one page", "Command Rightbracket"),
            ("address", "Focus address bar", "Command L"), ("navigate", "Navigate current tab to explicit HTTP(S) URL", nil),
            ("find", "Find literal text on page (does not click a result)", nil),
            ("find_next", "Next find match", "Command G"), ("find_previous", "Previous find match", "Command Shift G"),
            ("select_all", "Select all in the focused page or text field", "Command A"), ("copy", "Copy current selection", "Command C"),
            ("downloads", "Open downloads", "Command Shift J"), ("history", "Open history", "Command Y"),
            ("zoom_in", "Zoom in", "Command Shift Equals"), ("zoom_out", "Zoom out", "Command Minus"),
            ("zoom_reset", "Reset zoom", "Command 0")
        ]
        let codex: [(String, String, String?)] = [
            ("focus", "Focus Codex / ChatGPT desktop", nil), ("new_chat", "New chat", "Command N"),
            ("new_standalone", "New standalone chat", "Command Option O"),
            ("next_chat", "Next chat or tab", "Control Tab"), ("previous_chat", "Previous chat or tab", "Control Shift Tab"),
            ("attention", "Next chat needing attention", "Command Option A"),
            ("model_picker", "Open model picker (not select a model)", "Control Shift M"),
            ("project_picker", "Open project picker (not select a project)", "Command Option Shift O"),
            ("sidebar", "Toggle sidebar", "Command B"), ("bottom_panel", "Toggle bottom panel", "Command J"),
            ("file_tree", "Toggle file tree", "Command Shift E"), ("review", "Open review tab", "Control Shift G"),
            ("browser", "Open browser tab", "Command T"), ("find", "Focus find in chat", "Command F"),
            ("select_all", "Select all in the focused view or text field", "Command A"), ("copy", "Copy current selection", "Command C"),
            ("command_menu", "Open command menu", "Command Shift P"),
            ("keyboard_help", "Open keyboard shortcuts", "Command Slash"), ("settings", "Open settings", "Command Comma"),
            ("back", "Navigate back", "Command Leftbracket"), ("forward", "Navigate forward", "Command Rightbracket")
        ]
        return chrome.map { Action(id: "chrome." + $0.0, title: $0.1, chord: $0.2) }
            + codex.map { Action(id: "codex." + $0.0, title: $0.1, chord: $0.2) }
            + (1...8).map { Action(id: "chrome.tab_\($0)", title: "Select tab \($0) from left", chord: "Command \($0)") }
            + [Action(id: "chrome.last_tab", title: "Select last tab", chord: "Command 9")]
    }()

    static func action(_ id: String) -> Action? { catalog.first { $0.id == id } }

    static func decode(_ text: String, request: String) throws -> ShortcutPlan {
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              Set(object.keys) == ["route", "reason", "requiresConfirmation", "steps"],
              let steps = object["steps"] as? [[String: Any]],
              steps.allSatisfy({ Set($0.keys) == ["action", "argument"] }) else {
            throw Fault("Unexpected shortcut fields. No actions were sent.")
        }
        let plan = try JSONDecoder().decode(Self.self, from: Data(text.utf8))
        guard plan.reason.count <= 800, plan.steps.count <= 12,
              plan.route == .shortcuts ? !plan.steps.isEmpty : plan.steps.isEmpty else {
            throw Fault("Invalid shortcut plan. No actions were sent.")
        }
        for step in plan.steps {
            guard let action = action(step.action) else { throw Fault("Unknown shortcut. No actions were sent.") }
            if action.takesArgument {
                guard let argument = step.argument, !argument.isEmpty, argument.utf16.count <= 2000,
                      argument.rangeOfCharacter(from: .controlCharacters) == nil else { throw Fault("Invalid shortcut text.") }
                if step.action == "chrome.navigate" {
                    guard let url = URLComponents(string: argument), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                          let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
                          !argument.contains(" "), url.url != nil,
                          requestContainsURL(request, argument) else {
                        throw Fault("Say the full website address. Only explicit HTTP(S) URLs can use shortcuts.")
                    }
                } else if !request.localizedCaseInsensitiveContains(argument) {
                    throw Fault("The find text must come from your request.")
                }
            } else if step.argument != nil { throw Fault("Unexpected shortcut argument.") }
        }
        return plan
    }

    private static func requestContainsURL(_ request: String, _ argument: String) -> Bool {
        let normalized = request.replacingOccurrences(of: " dot ", with: ".", options: .caseInsensitive)
            .replacingOccurrences(of: " slash ", with: "/", options: .caseInsensitive)
        // Whole URL token, not a substring of another host/path. Ignore only
        // the optional spoken scheme; never drop spaces or lowercase paths.
        var address = argument.replacingOccurrences(of: "^https?://", with: "", options: .regularExpression)
        if let url = URLComponents(string: argument), url.path == "/", url.query == nil, url.fragment == nil { address.removeLast() }
        // A sentence-final period is punctuation, but .another-host is not.
        let pattern = "(?<![A-Za-z0-9_./:@%?&=#-])(?:https?://)?" + NSRegularExpression.escapedPattern(for: address) + "(?![A-Za-z0-9_/:@%?&=#-]|\\.[A-Za-z0-9])"
        return normalized.range(of: pattern, options: .regularExpression) != nil
    }

    static let schema: [String: Any] = [
        "type": "object", "additionalProperties": false,
        "required": ["route", "reason", "requiresConfirmation", "steps"],
        "properties": [
            "route": ["type": "string", "enum": ["shortcuts", "computer", "clarify"]],
            "reason": ["type": "string"], "requiresConfirmation": ["type": "boolean"],
            "steps": ["type": "array", "maxItems": 12, "items": ["type": "object", "additionalProperties": false,
                "required": ["action", "argument"], "properties": [
                    "action": ["type": "string", "enum": catalog.map(\.id)],
                    "argument": ["type": ["string", "null"]]
                ]]]
        ]
    ]

    static var instructions: String {
        """
        Analyze the user's macOS command. Do not execute it. Return only the required JSON.
        Choose shortcuts ONLY if the ENTIRE request can be fulfilled by 1–12 catalog actions without reading the screen. Prefer this route for routine Chrome and Codex navigation and explicit shortcut sequences. Expand repetitions. Each action targets its named app, not whichever app happens to be focused. Resolve an omitted app using ONLY the supplied initial focused bundle ID; if unsupported/unknown, use computer, never guess Chrome. Codex and ChatGPT refer to com.openai.codex.
        Choose computer for tasks needing visible context, named/numbered-item existence checks, selecting a particular model/project, clicking search results, playing a named video, filling/submitting forms, testing features, Simulator, unsupported apps/actions, or anything not wholly covered. Do not execute a shortcut prefix before computer use. If the request is ambiguous, contradictory, or only modifiers without a key, choose clarify with a concise question. Computer and clarify routes MUST have empty steps.
        For shortcuts, preserve the user's order and scope. Do not add actions, change settings, or infer destinations. Argument is null except chrome.navigate (explicit URL from the request; may normalize spoken dot/slash and add https://) and chrome.find (literal search text from request). Chrome new_tab then navigate is supported; navigate alone stays in the current tab. Never turn instructions into URL query parameters or navigate to invented URLs. Do not replace a requested named tab with an arbitrary numbered tab. Toggles cannot guarantee open/closed state; use computer when that state matters. Opening a picker is not choosing an item. No arbitrary typing, keycodes, Enter, terminal or console commands. No tools or external information needed.
        requiresConfirmation must be true for a sensitive or consequential action, disclosure/submission of user data, purchases, saved-data deletion, or changing settings. Routine user-specified web navigation needs no extra confirmation. reason is a brief proposed plan, never a claim of success.
        Catalog (id: purpose; keyboard chord):
        \(catalog.map { "\($0.id): \($0.title); \($0.chord ?? "built-in action")" }.joined(separator: "\n"))
        """
    }

    struct Fault: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
