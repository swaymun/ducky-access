import AppKit
import AVFoundation
import ServiceManagement
import OSLog

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
    let textInserter = TextInserter()

    private var statusItem: NSStatusItem!
    private var menu = NSMenu()
    private var recordingMode: RecordingMode?
    private var commandID: UUID?
    private var commandFocusApp: String?
    private var commandSession: CommandSession?
    private var commandApproval: NSAlert?
    private var speechStarting = false
    private var speechFinalizing = false
    private var model = "gpt-5.6-luna"
    private var effort = "low"
    private var serviceTier = "priority"
    private var commandPermissions = CommandPermissionProfile.load()
    private var availableModels: [String] = []
    private var usage: [UsageWindow] = []
    private var status: BridgeStatus = .starting
    private var lastError: String?
    private var permissions = ControlPermissions.read()
    private var permissionTimer: Timer?
    private let logger = Logger(subsystem: "com.swaymun.ducky-access", category: "controls")

    func start(showHelpOnLaunch: Bool = false) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "◉ Ducky"
        statusItem.menu = menu
        detector.onChange = { [weak self] connected in
            if !connected { self?.cancelCommand(); self?.appSwitcher.cancel() }
            self?.status = connected ? .ready : .disconnected
            self?.rebuildMenu()
        }
        keyboard.onAction = { [weak self] action in self?.handle(action) }
        help.onCommand = { [weak self] in self?.runTypedCommand(nil) }
        notch.onDismiss = { [weak self] in
            guard self?.commandID != nil else { return }
            self?.cancelCommand()
        }
        keyboard.filterUnmatchedEvent = { [weak self] type, event in
            guard let self else { return event }
            self.navigator.inputChanged(type)
            return self.appSwitcher.filterEvent(type, event)
        }
        navigator.onError = { [weak self] message in self?.lastError = message; self?.rebuildMenu() }
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
        logPermissions()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let current = ControlPermissions.read()
            guard current != self.permissions else { return }
            self.permissions = current
            self.logPermissions()
            self.keyboard.refreshPermissions()
            self.rebuildMenu()
        }
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
        logger.info("Handling pad action=\(String(describing: action), privacy: .public)")
        switch action {
        case .hint(let letter): navigator.handle(letter)
        case .navigate: navigator.toggle()
        case .dictate: toggleRecording(.dictate)
        case .command: toggleRecording(.command)
        case .enter:
            if appSwitcher.active { appSwitcher.finish() }
            else {
                navigator.close()
                if !KeyboardOutput.send(KeyboardShortcut(keyCode: 36, flags: [], keyName: "Return")) {
                    lastError = "Enable Accessibility to send Enter."
                    rebuildMenu()
                }
            }
        case .escape: cancelCurrent()
        case .volumeUp: postMediaKey(0x48)
        case .volumeDown: postMediaKey(0x49)
        case .mute: postMediaKey(0x4c)
        case .scrollUp: appSwitcher.active ? appSwitcher.next() : navigator.scroll(3)
        case .scrollDown: appSwitcher.active ? appSwitcher.previous() : navigator.scroll(-3)
        case .appSwitcher:
            navigator.close()
            appSwitcher.active ? appSwitcher.finish() : appSwitcher.begin()
        case .appNext: appSwitcher.next()
        case .appPrevious: appSwitcher.previous()
        }
    }

    private func toggleRecording(_ mode: RecordingMode) {
        if commandID != nil && recordingMode == nil { cancelCommand(); return }
        guard !speechStarting, !speechFinalizing else { NSSound.beep(); return }
        if recordingMode != nil { stopRecording(); return }
        guard status != .formatting else { NSSound.beep(); return }
        guard speech.modelReady else { NSSound.beep(); lastError = "Parakeet is still loading"; rebuildMenu(); return }
        navigator.close()
        lastError = nil
        recordingMode = mode
        let id = mode == .command ? UUID() : nil
        commandID = id
        if mode == .command { commandFocusApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
        notch.commandCancellable = mode == .command
        status = .recording
        notch.show(mode: mode)
        speechStarting = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await speech.start { [weak self] partial in
                    guard let self, mode != .command || self.commandID == id else { return }
                    self.notch.update(text: partial)
                }
                self.speechStarting = false
                if mode == .command && self.commandID != id { self.speech.cancel() }
            } catch {
                self.speechStarting = false
                self.commandID = nil; self.notch.commandCancellable = false
                self.recordingMode = nil; self.status = .error; self.lastError = error.localizedDescription; self.notch.hide(); self.rebuildMenu()
            }
        }
        rebuildMenu()
    }

    private func stopRecording() {
        guard let mode = recordingMode else { return }
        let id = commandID
        recordingMode = nil
        speechFinalizing = true
        status = .formatting
        notch.showResult("Finalizing…", status: mode == .dictate ? "Dictation" : "Command")
        speech.stop { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async {
                self.speechFinalizing = false
                if mode == .command && self.commandID != id {
                    if case .success(let value) = result, let url = value.audioURL { try? FileManager.default.removeItem(at: url) }
                    return // Cancelled while Parakeet was finalizing: never launch an agent.
                }
                switch result {
                case .failure(let error):
                    self.commandID = nil; self.notch.commandCancellable = false
                    self.status = .error; self.lastError = error.localizedDescription; self.notch.showResult(error.localizedDescription, status: "Error"); self.rebuildMenu()
                case .success(let value):
                    let audioData = value.audioURL.flatMap { try? Data(contentsOf: $0) }
                    if let url = value.audioURL { try? FileManager.default.removeItem(at: url) }
                    guard !value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        self.commandID = nil; self.notch.commandCancellable = false
                        self.status = .ready
                        self.notch.showResult("", status: "No speech detected")
                        self.rebuildMenu()
                        return
                    }
                    if mode == .dictate {
                        self.notch.showResult(value.text, status: "Formatting…")
                        self.appServer.format(value.text, model: self.model, effort: self.effort, serviceTier: self.serviceTier) { formatted in
                            DispatchQueue.main.async {
                                switch formatted {
                                case .success(let text):
                                    self.textInserter.insert(text) { outcome in
                                        self.history.add(raw: value.text, formatted: text, mode: mode, audioData: audioData, duration: value.duration, error: outcome.detail)
                                        self.notch.showResult(text, status: outcome.title, dismissAfter: 2.5)
                                        self.lastError = outcome.detail
                                        self.status = outcome.detail == nil ? .ready : .error
                                        self.rebuildMenu()
                                    }
                                case .failure(let error):
                                    self.history.add(raw: value.text, formatted: nil, mode: mode, audioData: audioData, duration: value.duration, error: error.localizedDescription)
                                    self.notch.showResult(value.text, status: "Raw transcript")
                                    self.status = .error; self.lastError = error.localizedDescription
                                }
                                self.rebuildMenu()
                            }
                        }
                    } else {
                        switch SpokenShortcut.parse(value.text) {
                        case .shortcut(let shortcut):
                            self.appSwitcher.cancel()
                            self.navigator.close()
                            let sent = KeyboardOutput.send(shortcut)
                            let resultText = sent ? "Sent \(shortcut.displayName)" : "Enable Accessibility to send shortcuts."
                            self.finishCommand(raw: value.text, resultText: resultText, audioData: audioData, duration: value.duration, error: sent ? nil : resultText)
                            return
                        case .invalid, .notShortcut: break
                        }
                        guard let id else { return }
                        self.runMultiStepCommand(value.text, id: id, audioData: audioData, duration: value.duration)
                    }
                }
            }
        }
        rebuildMenu()
    }

    private func finishCommand(raw: String, resultText: String, audioData: Data?, duration: TimeInterval, error: String? = nil) {
        commandID = nil
        notch.commandCancellable = false
        history.add(raw: raw, formatted: resultText, mode: .command, audioData: audioData, duration: duration, error: error)
        notch.showResult(resultText, status: error == nil ? "Command" : "Try again", dismissAfter: 2.5)
        lastError = error
        status = error == nil ? .ready : .error
        rebuildMenu()
    }

    private func runMultiStepCommand(_ text: String, id: UUID, audioData: Data?, duration: TimeInterval) {
        appSwitcher.cancel(); navigator.close()
        let session = CommandSession(permissionProfile: commandPermissions, routeShortcuts: true)
        commandSession = session
        session.onProgress = { [weak self] message in
            guard let self, self.commandID == id else { return }
            self.notch.showResult(message, status: "Command · click to stop")
        }
        session.onApproval = { [weak self] message, completion in
            guard let self, self.commandID == id else { completion(false); return }
            let alert = NSAlert()
            alert.messageText = "Allow this command step?"
            alert.informativeText = message
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Allow once")
            self.commandApproval = alert
            let target = NSWorkspace.shared.frontmostApplication
            let response = alert.runModal()
            self.commandApproval = nil
            let approved = self.commandID == id && response == .alertSecondButtonReturn
            if approved { target?.activate(options: [.activateAllWindows]) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { completion(self.commandID == id && approved) }
        }
        session.onFinish = { [weak self] outcome in
            guard let self else { return }
            self.history.add(raw: text, formatted: outcome.text, mode: .command, audioData: audioData, duration: duration, error: outcome.error)
            guard self.commandID == id else { return }
            if let alert = self.commandApproval {
                NSApp.abortModal(); alert.window.orderOut(nil); self.commandApproval = nil
            }
            self.commandSession = nil; self.commandID = nil
            self.notch.commandCancellable = false
            if outcome.cancelled { self.notch.hide() }
            else { self.notch.showResult(outcome.text, status: outcome.error == nil ? "Command" : "Needs attention", dismissAfter: 2.5) }
            self.lastError = outcome.error; self.status = outcome.error == nil ? .ready : .error
            self.rebuildMenu()
        }
        session.start(text, model: model, effort: effort, serviceTier: serviceTier, focusedApp: commandFocusApp)
    }

    func cancelCommand() {
        guard commandID != nil else { return }
        commandID = nil // Invalidate all late speech, model, and tool callbacks.
        if recordingMode == .command { recordingMode = nil; speech.cancel() }
        commandSession?.cancel(); commandSession = nil
        if let alert = commandApproval { NSApp.abortModal(); alert.window.orderOut(nil); commandApproval = nil }
        notch.commandCancellable = false; notch.hide()
        status = .ready; lastError = nil; rebuildMenu()
    }

    private func cancelCurrent() {
        if commandID != nil { cancelCommand() }
        else if recordingMode != nil { recordingMode = nil; speech.cancel(); notch.hide(); status = .ready }
        else if appSwitcher.active { appSwitcher.cancel() }
        else if navigator.active { navigator.close() }
        else { postEscape() }
        rebuildMenu()
    }

    private func logPermissions() {
        logger.info("Permissions accessibility=\(self.permissions.accessibility) keyboardOutput=\(self.permissions.keyboardOutput) inputMonitoring=\(self.permissions.inputMonitoring)")
    }

    private func postMediaKey(_ key: CGKeyCode) {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true); down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false); up?.post(tap: .cghidEventTap)
    }

    private func postEscape() {
        KeyboardOutput.send(KeyboardShortcut(keyCode: 53, flags: [], keyName: "Esc"))
    }

    @objc func showHelp(_ sender: Any?) { help.show() }
    @objc func runTypedCommand(_ sender: Any?) {
        guard commandID == nil, recordingMode == nil, !speechStarting, !speechFinalizing, status != .formatting else { NSSound.beep(); return }
        let focusedApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let alert = NSAlert()
        alert.messageText = "Run a computer command"
        alert.informativeText = "Describe the steps to perform. Click the notch or press ESC to stop. Actions already sent may finish."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
        field.placeholderString = "In Calculator, calculate twelve times seven"
        field.setAccessibilityLabel("Computer command")
        alert.accessoryView = field
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Run")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let id = UUID(); commandID = id; status = .formatting
        commandFocusApp = focusedApp
        notch.commandCancellable = true; notch.show(mode: .command)
        runMultiStepCommand(text, id: id, audioData: nil, duration: 0)
        rebuildMenu()
    }
    @objc func repairPermissions(_ sender: Any?) { ControlPermissions.openSettings() }
    @objc func showHistory(_ sender: Any?) { if let url = try? history.writeHTML() { NSWorkspace.shared.open(url) } }
    @objc func quit(_ sender: Any?) { cancelCommand(); appSwitcher.cancel(); navigator.close(); keyboard.stop(); appServer.stop(); NSApp.terminate(nil) }
    @objc func selectModel(_ sender: NSMenuItem) { if let value = sender.representedObject as? String { model = value; rebuildMenu() } }
    @objc func selectEffort(_ sender: NSMenuItem) { if let value = sender.representedObject as? String { effort = value; rebuildMenu() } }
    @objc func selectSpeed(_ sender: NSMenuItem) { if let value = sender.representedObject as? String { serviceTier = value == "Fast" ? "priority" : "default"; rebuildMenu() } }
    @objc func selectCommandPermissions(_ sender: NSMenuItem) {
        guard commandID == nil, let value = sender.representedObject as? String,
              let profile = CommandPermissionProfile(rawValue: value) else { return }
        commandPermissions = profile
        UserDefaults.standard.set(profile.rawValue, forKey: CommandPermissionProfile.defaultsKey)
        rebuildMenu()
    }
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
        case 6:
            let text = record.formattedText ?? record.rawText
            textInserter.insert(text) { [weak self] outcome in
                self?.notch.showResult(text, status: outcome.title, dismissAfter: 2.5)
                self?.lastError = outcome.detail
                self?.rebuildMenu()
            }
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
        let statusText = permissions.needsRepair && status == .ready ? "Accessibility needed" : status.rawValue
        let title = NSMenuItem(title: "Ducky Access — \(statusText)", action: nil, keyEquivalent: "")
        title.isEnabled = false; menu.addItem(title)
        let pad = NSMenuItem(title: detector.connected ? "Pad: Connected" : "Pad: Disconnected", action: nil, keyEquivalent: ""); pad.isEnabled = false; menu.addItem(pad)
        let permissionItem = NSMenuItem(title: permissions.needsRepair ? "Enable navigation & text insertion…" : "Navigation & text insertion: Allowed", action: permissions.needsRepair ? #selector(repairPermissions(_:)) : nil, keyEquivalent: "")
        permissionItem.target = self
        menu.addItem(permissionItem)
        menu.addItem(.separator())
        menu.addItem(submenu("Model: \(modelDisplay(model))", values: availableModels.isEmpty ? [model] : availableModels, selected: model, action: #selector(selectModel(_:))))
        menu.addItem(submenu("Reasoning: \(effort.capitalized)", values: ["none", "low", "medium", "high", "xhigh"], selected: effort, action: #selector(selectEffort(_:))))
        menu.addItem(submenu("Speed: \(serviceTier == "priority" ? "Fast" : "Default")", values: ["Default", "Fast"], selected: serviceTier == "priority" ? "Fast" : "Default", action: #selector(selectSpeed(_:))))
        let commandPermissionItem = submenu("Permissions: \(commandPermissions.rawValue)", values: CommandPermissionProfile.allCases.map(\.rawValue), selected: commandPermissions.rawValue, action: #selector(selectCommandPermissions(_:)))
        commandPermissionItem.toolTip = "Full Access runs commands without Ducky approval popups, including sensitive actions. Applies to the next command; macOS permissions and click-to-stop still apply."
        commandPermissionItem.submenu?.autoenablesItems = false
        commandPermissionItem.submenu?.items.forEach { $0.isEnabled = commandID == nil }
        menu.addItem(commandPermissionItem)
        let usageItem = NSMenuItem(title: usageTitle(), action: nil, keyEquivalent: ""); usageItem.isEnabled = false; menu.addItem(usageItem)
        if let lastError { let errorItem = NSMenuItem(title: "⚠ \(lastError)", action: nil, keyEquivalent: ""); errorItem.isEnabled = false; menu.addItem(errorItem) }
        menu.addItem(.separator())
        let commandItem = NSMenuItem(title: "Run command…", action: #selector(runTypedCommand(_:)), keyEquivalent: "")
        commandItem.target = self
        commandItem.isEnabled = commandID == nil && recordingMode == nil && status != .formatting
        menu.addItem(commandItem)
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
        for (title, tag) in [("Insert formatted", 6), ("Copy formatted", 1), ("Copy raw", 2), ("Play recording", 3), ("View all history", 4), ("Delete", 5)] {
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
