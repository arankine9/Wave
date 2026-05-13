import CryptoKit
import Foundation

/// Tracks how often each raw transcript pattern has been a no-op for the
/// cleanup LLM. Once a pattern has seen `threshold` consecutive
/// identity passes (raw == cleaned), the pipeline skips the LLM for
/// future occurrences and returns raw directly. Mutations reset the
/// counter so behavior re-learns when phrasing changes.
public final class IdentityCache: @unchecked Sendable {
    public struct Entry: Codable, Equatable {
        public var identityPasses: Int
        public var lastSeenISO: String
    }

    private struct Storage: Codable {
        var entries: [String: Entry]
    }

    private let file: URL
    private let threshold: Int
    private let queue = DispatchQueue(label: "com.wave.identitycache")
    private var storage: Storage

    public init(file: URL, threshold: Int = 200) {
        self.file = file
        self.threshold = threshold
        self.storage = Self.load(from: file) ?? Storage(entries: [:])
    }

    public func shouldSkip(raw: String) -> Bool {
        let key = Self.normalize(raw)
        return queue.sync {
            (storage.entries[key]?.identityPasses ?? 0) >= threshold
        }
    }

    public func recordIdentityPass(raw: String) {
        mutate(raw: raw) { current in
            current.identityPasses += 1
            current.lastSeenISO = Self.nowISO()
        }
    }

    public func recordMutation(raw: String) {
        mutate(raw: raw) { current in
            current.identityPasses = 0
            current.lastSeenISO = Self.nowISO()
        }
    }

    public func passes(raw: String) -> Int {
        let key = Self.normalize(raw)
        return queue.sync { storage.entries[key]?.identityPasses ?? 0 }
    }

    private func mutate(raw: String, _ block: (inout Entry) -> Void) {
        let key = Self.normalize(raw)
        queue.sync {
            var entry = storage.entries[key] ?? Entry(identityPasses: 0, lastSeenISO: Self.nowISO())
            block(&entry)
            storage.entries[key] = entry
            persist()
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(storage)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            // Cache is best-effort; failure to persist must not crash the app.
        }
    }

    private static func load(from file: URL) -> Storage? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Storage.self, from: data)
    }

    /// Hash on lowercased + whitespace-collapsed text. Same logical input maps
    /// to the same key regardless of capitalization or extra spaces.
    static func normalize(_ s: String) -> String {
        let lower = s.lowercased()
        let collapsed = lower.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let digest = SHA256.hash(data: Data(collapsed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func nowISO() -> String {
        let f = ISO8601DateFormatter()
        return f.string(from: Date())
    }
}
