import AppKit
import Foundation

final class HistoryStore {
    private let directory: URL
    private let metadataURL: URL
    private var records: [DictationRecord] = []

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DuckyAccess", isDirectory: true)
        directory = support
        metadataURL = support.appendingPathComponent("dictations.json")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        load()
    }

    var all: [DictationRecord] { records }
    var recent: [DictationRecord] { Array(records.prefix(5)) }

    func add(raw: String, formatted: String?, mode: RecordingMode, audioData: Data?, duration: TimeInterval, error: String?) {
        let audioName: String?
        if let audioData {
            let name = "\(UUID().uuidString).m4a"
            try? audioData.write(to: directory.appendingPathComponent(name), options: .atomic)
            audioName = name
        } else {
            audioName = nil
        }
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName
        records.insert(DictationRecord(
            id: UUID(), createdAt: Date(), mode: mode, rawText: raw,
            formattedText: formatted, audioFileName: audioName,
            destinationApp: appName, duration: duration, error: error
        ), at: 0)
        save()
    }

    func delete(_ id: UUID) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        if let name = record.audioFileName { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
        records.removeAll { $0.id == id }
        save()
    }

    func clear() {
        for record in records {
            if let name = record.audioFileName { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
        }
        records.removeAll()
        save()
    }

    func audioURL(for record: DictationRecord) -> URL? {
        guard let name = record.audioFileName else { return nil }
        let url = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func storageBytes() -> Int64 {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.reduce(0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return total + Int64(size)
        }
    }

    func writeHTML() throws -> URL {
        let folder = directory.appendingPathComponent("history", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var html = """
        <!doctype html><html><head><meta charset="utf-8"><title>Ducky Access History</title>
        <style>body{font:15px -apple-system,BlinkMacSystemFont,sans-serif;max-width:900px;margin:40px auto;padding:0 24px;color:#172033;background:#f5f7fb}article{background:white;border:1px solid #dfe5ef;border-radius:14px;padding:20px;margin:16px 0;box-shadow:0 4px 18px #17203312}h1{margin-bottom:4px}h2{font-size:16px;margin-bottom:4px}small{color:#68758c}pre{white-space:pre-wrap;background:#f5f7fb;border-radius:8px;padding:12px}audio{width:100%}.formatted{border-left:3px solid #5b6cff;padding-left:12px}</style></head><body><h1>Ducky Access</h1><p>Dictation history · (records.count) entries · (ByteCountFormatter.string(fromByteCount: storageBytes(), countStyle: .file))</p>
        """
        for record in records {
            let date = record.createdAt.formatted(date: .abbreviated, time: .shortened)
            let raw = escape(record.rawText)
            let formatted = escape(record.formattedText ?? "Not formatted")
            let audio = record.audioFileName.map { "<audio controls src=\"../\(escape($0))\"></audio>" } ?? "<small>No recording saved</small>"
            html += "<article><h2>\(escape(record.mode.rawValue.capitalized)) · \(escape(record.destinationApp ?? "Unknown app"))</h2><small>\(escape(date)) · \(String(format: "%.1fs", record.duration))</small><h3>Formatted</h3><div class=\"formatted\">\(formatted)</div><h3>Raw</h3><pre>\(raw)</pre>\(audio)</article>"
        }
        html += "</body></html>"
        let url = folder.appendingPathComponent("index.html")
        try html.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func load() {
        guard let data = try? Data(contentsOf: metadataURL), let loaded = try? JSONDecoder().decode([DictationRecord].self, from: data) else { return }
        records = loaded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: metadataURL, options: .atomic)
    }
}
