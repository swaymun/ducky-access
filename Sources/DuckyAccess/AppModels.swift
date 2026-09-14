import Foundation

enum RecordingMode: String, Codable {
    case dictate
    case command
}

enum BridgeStatus: String {
    case starting = "Starting"
    case ready = "Ready"
    case recording = "Recording"
    case formatting = "Formatting"
    case disconnected = "Pad disconnected"
    case error = "Needs attention"
}

struct DictationRecord: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let mode: RecordingMode
    let rawText: String
    let formattedText: String?
    let audioFileName: String?
    let destinationApp: String?
    let duration: TimeInterval
    let error: String?
}

struct UsageWindow {
    let label: String
    let usedPercent: Double
    let resetDate: Date?

    var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }
}

enum PadAction {
    case hint(Character)
    case navigate
    case dictate
    case command
    case backspace
    case escape
    case volumeUp
    case volumeDown
    case mute
    case scrollUp
    case scrollDown
    case appSwitcher
    case appNext
    case appPrevious
}
