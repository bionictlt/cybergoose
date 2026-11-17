import Foundation

@main
struct LocalFileSystemChecks {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("hello".utf8).write(to: root.appendingPathComponent("hello.txt"))
        try Data().write(to: root.appendingPathComponent(".hidden"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: false)
        let fs = LocalFileSystem()
        let visible = try await fs.contents(at: root, showHidden: false)
        precondition(Set(visible.entries.map(\.name)) == ["hello.txt", "folder"])
        precondition(visible.entries.first { $0.name == "hello.txt" }?.size == 5)
        precondition(visible.entries.first { $0.name == "folder" }?.isDirectory == true)
        let all = try await fs.contents(at: root, showHidden: true)
        precondition(all.entries.count == 3)
        var failed = false
        do { _ = try await fs.contents(at: root.appendingPathComponent("missing"), showHidden: false) }
        catch { failed = true }
        precondition(failed)
        print("Passed: directory listing, metadata, hidden files, missing directory")
    }
}
