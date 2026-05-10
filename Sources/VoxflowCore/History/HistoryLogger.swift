import Foundation

/// JSON-lines history logger. Each dictation appends one line to a file in
/// the user's Application Support directory. SQLite/GRDB can replace this
/// when the history panel needs queries beyond "last N lines".
public final class HistoryLogger: DictationLogger, @unchecked Sendable {
    private let file: URL
    private let queue = DispatchQueue(label: "com.voxflow.history")

    public init(file: URL) {
        self.file = file
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
    }

    public static func defaultURL() -> URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Voxflow", isDirectory: true)
            .appendingPathComponent("history.jsonl")
    }

    public func record(_ trace: DictationTrace) {
        queue.async { [file] in
            let line = HistoryLine(
                timestampISO: ISO8601DateFormatter().string(from: Date()),
                rawTranscript: trace.rawTranscript,
                finalText: trace.finalText,
                path: trace.path.rawValue,
                inputTokens: trace.inputTokens,
                outputTokens: trace.outputTokens,
                sttMs: trace.sttMs,
                cleanupMs: trace.cleanupMs,
                pasteMs: trace.pasteMs
            )
            guard let data = try? JSONEncoder().encode(line) else { return }
            var withNewline = data
            withNewline.append(0x0A) // \n
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: withNewline)
            } else {
                try? withNewline.write(to: file)
            }
        }
    }

    /// Reads the last `n` lines from history. Used by the history panel.
    public func recent(limit: Int) -> [HistoryLine] {
        guard let data = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let lines = data.split(whereSeparator: { $0 == "\n" }).suffix(limit)
        let decoder = JSONDecoder()
        return lines.compactMap { line -> HistoryLine? in
            guard let bytes = String(line).data(using: .utf8) else { return nil }
            return try? decoder.decode(HistoryLine.self, from: bytes)
        }
    }
}

public struct HistoryLine: Codable, Equatable, Sendable {
    public let timestampISO: String
    public let rawTranscript: String
    public let finalText: String
    public let path: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let sttMs: Int
    public let cleanupMs: Int
    public let pasteMs: Int
}
