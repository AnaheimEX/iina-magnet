import Foundation

public struct PluginLocalPathResolver: Sendable {
    public let dataRoot: URL
    public let temporaryRoot: URL

    public init(dataRoot: URL, temporaryRoot: URL) {
        self.dataRoot = dataRoot.standardizedFileURL
        self.temporaryRoot = temporaryRoot.standardizedFileURL
    }

    public func resolve(_ path: String) throws -> URL {
        guard !path.isEmpty, !path.contains("\0"), !path.hasPrefix("/") else {
            throw BundledPluginCoreError.invalidLocalPath(path)
        }
        let root: URL
        let name: Substring
        if path.hasPrefix("@data/") {
            root = dataRoot
            name = path.dropFirst("@data/".count)
        } else if path.hasPrefix("@tmp/") {
            root = temporaryRoot
            name = path.dropFirst("@tmp/".count)
        } else {
            throw BundledPluginCoreError.invalidLocalPath(path)
        }
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\\") else {
            throw BundledPluginCoreError.invalidLocalPath(path)
        }
        return root.appendingPathComponent(String(name), isDirectory: false).standardizedFileURL
    }
}
