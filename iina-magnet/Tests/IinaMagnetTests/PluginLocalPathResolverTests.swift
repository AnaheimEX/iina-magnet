import Foundation
import Testing
@testable import IinaMagnet

@Suite struct PluginLocalPathResolverTests {
    @Test func resolvesOnlyFlatDataAndTemporaryFiles() throws {
        let dataRoot = URL(fileURLWithPath: "/tmp/anime4k data", isDirectory: true)
        let temporaryRoot = URL(fileURLWithPath: "/tmp/anime4k temp", isDirectory: true)
        let resolver = PluginLocalPathResolver(dataRoot: dataRoot, temporaryRoot: temporaryRoot)

        #expect(try resolver.resolve("@data/shader.glsl")
            == dataRoot.appendingPathComponent("shader.glsl").standardizedFileURL)
        #expect(try resolver.resolve("@tmp/manifest.json")
            == temporaryRoot.appendingPathComponent("manifest.json").standardizedFileURL)
        #expect(try resolver.resolve("@data/空 格:shader.glsl")
            == dataRoot.appendingPathComponent("空 格:shader.glsl").standardizedFileURL)
    }

    @Test func rejectsTraversalNestedAbsoluteAndUnsupportedPaths() {
        let resolver = PluginLocalPathResolver(
            dataRoot: URL(fileURLWithPath: "/tmp/data"),
            temporaryRoot: URL(fileURLWithPath: "/tmp/temp")
        )
        let invalid = [
            "", "/tmp/file", "@data/", "@tmp/", "@data/.", "@data/..",
            "@data/../file", "@data/./file", "@data/nested/file",
            "@tmp/nested/file", "@data/nested\\file", "@cache/file",
            "data/file", "@data/a\0b",
        ]
        for path in invalid {
            do {
                _ = try resolver.resolve(path)
                Issue.record("accepted unsafe plugin-local path: \(path)")
            } catch is BundledPluginCoreError {
                // Expected.
            } catch {
                Issue.record("unexpected error for \(path): \(error)")
            }
        }
    }
}
