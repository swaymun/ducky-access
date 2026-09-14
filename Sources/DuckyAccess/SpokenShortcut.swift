import AppKit

struct KeyboardShortcut: Equatable {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
    let keyName: String

    var displayName: String {
        var prefix = ""
        for (flag, symbol) in [(CGEventFlags.maskControl, "⌃"), (.maskAlternate, "⌥"), (.maskShift, "⇧"), (.maskCommand, "⌘")] {
            if flags.contains(flag) { prefix += symbol }
        }
        return prefix + keyName
    }
}

enum SpokenShortcut {
    enum ParseResult: Equatable {
        case shortcut(KeyboardShortcut)
        case invalid(String)
        case notShortcut
    }

    // Parse only a literal chord, never an inferred action or a sequence.
    // This stays local; ordinary speech still goes to the bounded classifier.
    static func parse(_ transcript: String) -> ParseResult {
        var text = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for (phrase, replacement) in [
            ("page up", "pageup"), ("page down", "pagedown"), ("space bar", "space"),
            ("up arrow", "up"), ("down arrow", "down"), ("left arrow", "left"), ("right arrow", "right"),
            ("arrow up", "up"), ("arrow down", "down"), ("arrow left", "left"), ("arrow right", "right"),
            ("forward delete", "forwarddelete")
        ] { text = text.replacingOccurrences(of: phrase, with: replacement) }
        for (symbol, name) in [("⌘", " command "), ("⌃", " control "), ("⌥", " option "), ("⇧", " shift ")] {
            text = text.replacingOccurrences(of: symbol, with: name)
        }
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "+-,.!?"))
        var words = text.components(separatedBy: separators).filter { !$0.isEmpty }
        let hasPressPrefix = ["press", "hit", "shortcut"].contains(words.first ?? "")
        if hasPressPrefix { words.removeFirst() }
        if words.first == "the" { words.removeFirst() }
        if ["key", "keys"].contains(words.last ?? "") { words.removeLast() }
        let modifiers: [String: CGEventFlags] = [
            "command": .maskCommand, "cmd": .maskCommand, "comand": .maskCommand,
            "control": .maskControl, "ctrl": .maskControl,
            "option": .maskAlternate, "alt": .maskAlternate, "shift": .maskShift
        ]
        let hasModifier = words.contains { modifiers[$0] != nil }
        var flags: CGEventFlags = []
        var keyWords: [String] = []
        for word in words {
            if let flag = modifiers[word] { flags.insert(flag) }
            else if word != "plus" && word != "and" { keyWords.append(word) }
        }
        guard hasModifier || hasPressPrefix || (keyWords.count == 1 && namedKeys[keyWords[0]] != nil) else { return .notShortcut }
        guard keyWords.count == 1 else {
            return .invalid(keyWords.isEmpty ? "Add a key, like Control Option Command T." : "Say one shortcut at a time, like Command Shift T.")
        }
        let name = keyWords[0]
        if let key = namedKeys[name] {
            return .shortcut(KeyboardShortcut(keyCode: key.0, flags: flags, keyName: key.1))
        }
        if let code = characterKeys[name] {
            return .shortcut(KeyboardShortcut(keyCode: code, flags: flags, keyName: name.uppercased()))
        }
        return .invalid("Key not recognized. Try Command T or press Enter.")
    }

    // macOS ANSI key positions, matching the English duckyPad profile.
    private static let characterKeys: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46
    ]
    private static let namedKeys: [String: (CGKeyCode, String)] = [
        "enter": (36, "Return"), "return": (36, "Return"), "tab": (48, "Tab"),
        "escape": (53, "Esc"), "esc": (53, "Esc"), "space": (49, "Space"),
        "backspace": (51, "Delete"), "delete": (51, "Delete"), "forwarddelete": (117, "Forward Delete"),
        "up": (126, "↑"), "down": (125, "↓"), "left": (123, "←"), "right": (124, "→"),
        "home": (115, "Home"), "end": (119, "End"), "pageup": (116, "Page Up"), "pagedown": (121, "Page Down"),
        "comma": (43, ","), "period": (47, "."), "slash": (44, "/"), "backslash": (42, "\\"),
        "minus": (27, "−"), "equals": (24, "="), "backtick": (50, "`"),
        "f1": (122, "F1"), "f2": (120, "F2"), "f3": (99, "F3"), "f4": (118, "F4"),
        "f5": (96, "F5"), "f6": (97, "F6"), "f7": (98, "F7"), "f8": (100, "F8"),
        "f9": (101, "F9"), "f10": (109, "F10"), "f11": (103, "F11"), "f12": (111, "F12")
    ]
}

enum KeyboardOutput {
    static let eventTag: Int64 = 0x4455434B595357

    @discardableResult
    static func send(_ shortcut: KeyboardShortcut) -> Bool {
        guard CGPreflightPostEventAccess(), let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: false) else { return false }
        for event in [down, up] {
            event.flags = shortcut.flags
            event.setIntegerValueField(.eventSourceUserData, value: eventTag)
            event.post(tap: .cghidEventTap)
        }
        return true
    }
}
