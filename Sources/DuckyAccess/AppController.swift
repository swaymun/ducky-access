import AppKit
import AVFoundation
import ServiceManagement

final class DuckyAccessController: NSObject {
    let detector = DuckyPadDetector()
    let keyboard = KeyboardRouter()
    let navigator = AccessibilityNavigator()
    let appSwitcher = AppSwitcher()
    let speech = SpeechCapture()
    let appServer = AppServerClient()
    let history = HistoryStore()
    let notch = NotchPanelController()
    let help = HelpPanelController()

    private var statusItem: NSStatusItem!
    private var menu = NSMenu()
    private var recordingMode: RecordingMode?
    private var model = "gpt-5.6-luna"
    private var effort = "low"
    private var serviceTier = "priority"
    private var availableModels: [String] = []
    private var usage: [UsageWindow] = []
    private var status: BridgeStatus = .starting
    private var lastError: String?

    func start(showHelpOnLaunch: Bool = false) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "◉ Ducky"
        statusItem.menu = menu
        detector.onChange = { [weak self] connected in
            self?.status = connected ? .ready : .disconnected
            self?.rebuildMenu()
        }
        keyboard.onAction = { [weak self] action in self?.handle(action) }
        appServer.onReady = { [weak self] in self?.rebuildMenu() }
        appServer.onModels = { [weak self] models in self?.availableModels = models; self?.rebuildMenu() }
        appServer.onUsage = { [weak self] usage in self?.usage = usage; self?.rebuildMenu() }
        appServer.onError = { [weak self] message in self?.lastError = message; self?.status = .error; self?.rebuildMenu() }
        speech.onModelState = { [weak self] message in
            DispatchQueue.main.async {
                if message.contains("unavailable") { self?.lastError = message; self?.status = .error }
                self?.rebuildMenu()
            }
        }
        keyboard.start(using: detector)
        detector.start()
        appServer.start()
        speech.warm()
        requestMicrophoneAccess()
        try? SMAppService.mainApp.register()
        rebuildMenu()
        if showHelpOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.help.show() }
        }
    }

    private func requestMicrophoneAccess() {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            guard !granted else { return }
            DispatchQueue.main.async {
                self?.lastError = "Microphone permission is required for Dictate and Command"
                self?.rebuildMenu()
            }
        }
    }

    private func handle(_ action: PadAction) {
        switch action {
        case .hint(let letter): navigator.handle(letter)
        case .navigate: navigator.toggle()
        case .dictate: toggleRecording(.dictate)
        case .command: toggleRecording(.command)
        case .backspace: navigator.backspace()
        case .escape: cancelCurrent()
        case .volumeUp: postMediaKey(0x48)
        case .volumeDown: postMediaKey(0x49)
        case .mute: postMediaKey(0x4c)
        case .scrollUp: appSwitcher.active ? appSwitcher.next() : navigator.scroll(3)
        case .scrollDown: appSwitcher.active ? appSwitcher.previous() : navigator.scroll(-3)
        case .appSwitcher: appSwitcher.active ? appSwitcher.finish() : appSwitcher.begin()
        case .appNext: appSwitcher.next()
        case .appPrevious: appSwitcher.previous()
        }
    }

    private func toggleRecording(_ mode: RecordingMode) {
        if recordingMode != nil { stopRecording(); return }
        guard speech.modelReady else { NSSound.beep(); lastError = "Parakeet is still loading"; rebuildMenu(); return }
        recordingMode = mode
        status = .recording
        notch.show(mode: mode)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await speech.start { [weak self] partial in self?.notch.update(text: partial) }
            } catch {
                self.recordingMode = nil; self.status = .error; self.lastError = error.localizedDescription; self.notch.hide(); self.rebuildMenu()
            }
        }
        rebuildMenu()
    }

    private func stopRecording() {
        guard let mode = recordingMode else { return }
        recordingMode = nil
        status = .formatting
        notch.showResult("Finalizing…", status: mode == .dictate ? "Dictation" : "Command")
        speech.stop { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    self.status = .error; self.lastError = error.localizedDescription; self.notch.showResult(error.localizedDescription, status: "Error"); self.rebuildMenu()
                case .success(let value):
                    let audioData = value.audioURL.flatMap { try? Data(contentsOf: $0) }
                    if let url = value.audioURL { try? FileManager.default.removeItem(at: url) }
                    if mode == .dictate {
                        self.notch.showResult(value.text, status: "Formatting…")
                        self.appServer.format(value.text, model: self.model, effort: self.effort, serviceTier: self.serviceTier) { formatted in
                            DispatchQueue.main.async {
                                switch formatted {
                                case .success(let text):
                                    self.history.add(raw: value.text, formatted: text, mode: mode, audioData: audioData, duration: value.duration, error: nil)
                                    let inserted = self.insert(text)
                                    self.notch.showResult(text, status: inserted ? "Inserted" : "Copied")
                                    self.status = .ready
                                case .failure(let error):
                                    self.history.add(raw: value.text, formatted: nil, mode: mode, audioData: audioData, duration: value.duration, error: error.localizedDescription)
                                    self.notch.showResult(value.text, status: "Raw transcript")
                                    self.status = .error; self.lastError = error.localizedDescription
                                }
                                self.rebuildMenu()
                            }
                        }
                    } else {
                        self.appServer.routeCommand(value.text, model: self.model, effort: self.effort, serviceTier: self.serviceTier) { routed in
                            DispatchQueue.main.async {
                                let resultText = self.execute(routed)
                                self.history.add(raw: value.text, formatted: resultText, mode: mode, audioData: audioData, duration: value.duration, error: nil)
                                self.notch.showResult(resultText, status: "Command")
                                self.status = .ready
                                self.rebuildMenu()
                            }
                        }
                    }
                }
            }
        }
        rebuildMenu()
    }

    private func cancelCurrent() {
        if recordingMode != nil { recordingMode = nil; speech.cancel(); notch.hide(); status = .ready }
        else if appSwitcher.active { appSwitcher.cancel() }
        else if navigator.active { navigator.close() }
        else { postEscape() }
        rebuildMenu()
    }

    @discardableResult
    private func insert(_ text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        let old = pasteboard.string(forType: .string)
        pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
        let commandV = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true)
        commandV?.flags = .maskCommand; commandV?.post(tap: .cghidEventTap)
        let commandVUp = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false)
        commandVUp?.flags = .maskCommand; commandVUp?.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            pasteboard.clearContents()
            if let old { pasteboard.setString(old, forType: .string) }
        }
        return commandV != nil && commandVUp != nil
    }

    private func execute(_ result: Result<AppServerClient.JSON, Error>) -> String {
        guard case .success(let object) = result else { return "Command could not be classified." }
        switch object["action"] as? String {
        case "focus_app":
            let target = object["target"] as? String ?? ""
            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName?.localizedCaseInsensitiveContains(target) == true }) { app.activate(options: [.activateAllWindows]); return "Focused \(app.localizedName ?? target)." }
            return "Could not find \(target)."
        case "open_url":
            guard let raw = object["url"] as? String, let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased()) else { return "The URL was not allowed." }
            NSWorkspace.shared.open(url); return "Opened \(url.absoluteString)."
        case "switch_tab":
            let backward = (object["direction"] as? String)?.lowercased() == "previous"
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: true); event?.flags = backward ? [.maskCommand, .maskShift] : .maskCommand; event?.post(tap: .cghidEventTap)
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: false); up?.flags = backward ? [.maskCommand, .maskShift] : .maskCommand; up?.post(tap: .cghidEventTap)
            return backward ? "Previous tab." : "Next tab."
        case "scroll": navigator.scroll((object["direction"] as? String)?.lowercased() == "down" ? -3 : 3); return "Scrolled."
        default: return "I need a clearer allowed command."
        }
    }

    private func postMediaKey(_ key: CGKeyCode) {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true); down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false); up?.post(tap: .cghidEventTap)
    }

    private func postEscape() {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true); down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false); up?.post(tap: .cghidEventTap)
    }

    @objc func showHelp(_ sender: Any?) { help.show() }
    @objc func showHistory(_ sender: Any?) { if let url = try? history.writeHTML() { NSWorkspace.shared.open(url) } }
    @objc func quit(_ sender: Any?) { appSwitcher.cancel(); navigator.close(); keyboard.stop(); appServer.stop(); NSApp.terminate(nil) }
    @objc func selectModel(_ sender: NSMenuItem) { if let value = sender.representedObject as? String { model = value; rebuildMenu() } }
    @objc func selectEffort(_ sender: NSMenuItem) { if let value = sender.representedObject as? String { effort = value; rebuildMenu() } }
    @objc func selectSpeed(_ sender: NSMenuItem) { if let value = sender.representedObject as? String { serviceTier = value == "Fast" ? "priority" : "default"; rebuildMenu() } }
    @objc func recordFromMenu(_ sender: Any?) { toggleRecording(.dictate) }
    @objc func clearHistory(_ sender: Any?) { if NSAlert.showConfirm("Delete all dictations?", informative: "This removes saved text and recordings.") { history.clear(); rebuildMenu() } }
    @objc func dictationAction(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? String, let id = UUID(uuidString: idString), let record = history.all.first(where: { $0.id == id }) else { return }
        switch sender.tag {
        case 1: NSPasteboard.general.clearContents(); NSPasteboard.general.setString(record.formattedText ?? record.rawText, forType: .string)
        case 2: NSPasteboard.general.clearContents(); NSPasteboard.general.setString(record.rawText, forType: .string)
        case 3: if let url = history.audioURL(for: record) { NSWorkspace.shared.open(url) }
        case 4: showHistory(nil)
        case 5: history.delete(id); rebuildMenu()
        default: break
        }
    }

    private func rebuildMenu() {
        // Replace the menu atomically. AppKit may be walking the current menu
        // while async hardware/model callbacks arrive; mutating it in place
        // can raise "collection was mutated while being enumerated".
        let menu = NSMenu()
        self.menu = menu
        statusItem?.menu = menu
        let title = NSMenuItem(title: "Ducky Access — \(status.rawValue)", action: nil, keyEquivalent: "")
        title.isEnabled = false; menu.addItem(title)
        let pad = NSMenuItem(title: detector.connected ? "Pad: Connected" : "Pad: Disconnected", action: nil, keyEquivalent: ""); pad.isEnabled = false; menu.addItem(pad)
        menu.addItem(.separator())
        menu.addItem(submenu("Model: \(modelDisplay(model))", values: availableModels.isEmpty ? [model] : availableModels, selected: model, action: #selector(selectModel(_:))))
        menu.addItem(submenu("Reasoning: \(effort.capitalized)", values: ["none", "low", "medium", "high", "xhigh"], selected: effort, action: #selector(selectEffort(_:))))
        menu.addItem(submenu("Speed: \(serviceTier == "priority" ? "Fast" : "Default")", values: ["Default", "Fast"], selected: serviceTier == "priority" ? "Fast" : "Default", action: #selector(selectSpeed(_:))))
        let usageItem = NSMenuItem(title: usageTitle(), action: nil, keyEquivalent: ""); usageItem.isEnabled = false; menu.addItem(usageItem)
        if let lastError { let errorItem = NSMenuItem(title: "⚠ \(lastError)", action: nil, keyEquivalent: ""); errorItem.isEnabled = false; menu.addItem(errorItem) }
        menu.addItem(.separator())
        let recent = history.recent
        if recent.isEmpty { let empty = NSMenuItem(title: "No dictations yet", action: nil, keyEquivalent: ""); empty.isEnabled = false; menu.addItem(empty) }
        for record in recent { menu.addItem(dictationMenu(record)) }
        let historyItem = NSMenuItem(title: "All dictations…", action: #selector(showHistory(_:)), keyEquivalent: "")
        historyItem.target = self; menu.addItem(historyItem)
        let helpItem = NSMenuItem(title: "Help & keyboard map…", action: #selector(showHelp(_:)), keyEquivalent: "")
        helpItem.target = self; menu.addItem(helpItem)
        let clearHistoryItem = NSMenuItem(title: "Delete all dictations…", action: #selector(clearHistory(_:)), keyEquivalent: "")
        clearHistoryItem.target = self; menu.addItem(clearHistoryItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Ducky Access", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self; menu.addItem(quitItem)
    }

    private func submenu(_ title: String, values: [String], selected: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let child = NSMenu()
        for value in values {
            let choice = NSMenuItem(title: modelDisplay(value), action: action, keyEquivalent: "")
            choice.target = self; choice.representedObject = value; choice.state = value == selected ? .on : .off; child.addItem(choice)
        }
        item.submenu = child; return item
    }

    private func dictationMenu(_ record: DictationRecord) -> NSMenuItem {
        let title = "\(menuPreview(for: record)) · \(record.createdAt.formatted(date: .omitted, time: .shortened))"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.toolTip = record.formattedText ?? record.rawText
        let child = NSMenu(); let id = record.id.uuidString
        for (title, tag) in [("Copy formatted", 1), ("Copy raw", 2), ("Play recording", 3), ("View all history", 4), ("Delete", 5)] {
            let action = NSMenuItem(title: title, action: #selector(dictationAction(_:)), keyEquivalent: ""); action.target = self; action.tag = tag; action.representedObject = id; child.addItem(action)
        }
        item.submenu = child; return item
    }

    private func menuPreview(for record: DictationRecord) -> String {
        let source = [record.formattedText, record.rawText]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "No text"
        let singleLine = source
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let limit = 42
        return singleLine.count > limit ? String(singleLine.prefix(limit)) + "…" : singleLine
    }

    private func modelDisplay(_ value: String) -> String { value.replacingOccurrences(of: "gpt-5.6-", with: "").replacingOccurrences(of: "gpt-", with: "").capitalized }
    private func usageTitle() -> String { guard let first = usage.first else { return "Codex usage: unavailable" }; return String(format: "Codex usage: %.0f%% remaining · %@", first.remainingPercent, first.label) }
}

private extension NSAlert {
    static func showConfirm(_ message: String, informative: String) -> Bool {
        let alert = NSAlert(); alert.messageText = message; alert.informativeText = informative; alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel"); return alert.runModal() == .alertFirstButtonReturn
    }
}
