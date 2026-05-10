import XCTest
@testable import VoxflowCore

final class IdentityCacheTests: XCTestCase {
    private func tempFile() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxflow-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cache.json")
    }

    func testReachesThresholdAfterRepeatedPasses() {
        let cache = IdentityCache(file: tempFile(), threshold: 5)
        let raw = "hello there"
        XCTAssertFalse(cache.shouldSkip(raw: raw))
        for _ in 0..<5 { cache.recordIdentityPass(raw: raw) }
        XCTAssertTrue(cache.shouldSkip(raw: raw))
        XCTAssertEqual(cache.passes(raw: raw), 5)
    }

    func testMutationResetsCounter() {
        let cache = IdentityCache(file: tempFile(), threshold: 3)
        let raw = "foo bar"
        for _ in 0..<3 { cache.recordIdentityPass(raw: raw) }
        XCTAssertTrue(cache.shouldSkip(raw: raw))
        cache.recordMutation(raw: raw)
        XCTAssertFalse(cache.shouldSkip(raw: raw))
        XCTAssertEqual(cache.passes(raw: raw), 0)
    }

    func testNormalizationCollapsesCaseAndWhitespace() {
        let cache = IdentityCache(file: tempFile(), threshold: 2)
        cache.recordIdentityPass(raw: "Hello World")
        cache.recordIdentityPass(raw: "  hello   WORLD ")
        XCTAssertTrue(cache.shouldSkip(raw: "hello world"))
    }

    func testPersistsAcrossInstances() {
        let url = tempFile()
        do {
            let cache = IdentityCache(file: url, threshold: 2)
            cache.recordIdentityPass(raw: "ping")
            cache.recordIdentityPass(raw: "ping")
        }
        let restored = IdentityCache(file: url, threshold: 2)
        XCTAssertTrue(restored.shouldSkip(raw: "ping"))
    }
}
