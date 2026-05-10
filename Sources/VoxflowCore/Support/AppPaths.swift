import Foundation

public enum AppPaths {
    public static func appSupportDirectory() -> URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        let dir = support.appendingPathComponent("Voxflow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func identityCacheURL() -> URL {
        appSupportDirectory().appendingPathComponent("identity-cache.json")
    }
}
