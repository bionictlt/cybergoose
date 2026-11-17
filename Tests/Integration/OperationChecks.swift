import Foundation

@main
struct OperationChecks {
    @MainActor static func main() async {
        do { try await check(); print("Passed: queue order/retry/cancel, overwrite-all scope, copy/move/skip, recursive merge, cancellation, source protection, names, atomic editor saves") }
        catch { print("Operation checks failed: \(error)"); exit(1) }
    }
    @MainActor static func check() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cg-operations-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let from = root.appendingPathComponent("from"), to = root.appendingPathComponent("to")
        try FileManager.default.createDirectory(at: from, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
        let source = from.appendingPathComponent("file.txt"), target = to.appendingPathComponent("file.txt")
        try Data("new contents".utf8).write(to: source)
        try Data("old contents".utf8).write(to: target)
        let skip = FileTransferEngine(conflict: { _ in .skip }, progress: { _ in }, cancellation: CancellationFlag())
        let skipped = try await skip.transfer(FileLocation(source), to: FileLocation(target), move: true)
        precondition(!skipped && FileManager.default.fileExists(atPath: source.path))
        let oldData = try Data(contentsOf: target); precondition(oldData == Data("old contents".utf8))
        let overwrite = FileTransferEngine(conflict: { _ in .overwrite }, progress: { _ in }, cancellation: CancellationFlag())
        try await overwrite.transfer(FileLocation(source), to: FileLocation(target), move: true)
        precondition(!FileManager.default.fileExists(atPath: source.path))
        let newData = try Data(contentsOf: target); precondition(newData == Data("new contents".utf8))
        var rejectedClosedRemote = false
        do { _ = try await FileLocation(RemotePath(target.path).url).metadata() }
        catch { rejectedClosedRemote = true }
        precondition(rejectedClosedRemote, "A disconnected remote path must never resolve as a local path")
        let cancelled = CancellationFlag(); cancelled.cancel()
        var failed = false
        do { try await FileTransferEngine(conflict: { _ in .overwrite }, progress: { _ in }, cancellation: cancelled).transfer(FileLocation(target), to: FileLocation(source), move: true) }
        catch is CancellationError { failed = true }
        precondition(failed && FileManager.default.fileExists(atPath: target.path))
        let sub = from.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("child".utf8).write(to: sub.appendingPathComponent("child"))
        try await overwrite.transfer(FileLocation(sub), to: FileLocation(to.appendingPathComponent("folder")), move: true)
        precondition(!FileManager.default.fileExists(atPath: sub.path))
        precondition(FileManager.default.fileExists(atPath: to.appendingPathComponent("folder/child").path))
        failed = false
        do { try await overwrite.transfer(FileLocation(to), to: FileLocation(to.appendingPathComponent("inside")), move: false) }
        catch { failed = true }
        precondition(failed && !FileManager.default.fileExists(atPath: to.appendingPathComponent("inside").path))
        precondition(FileNames.newFolder(existing: []) == "Новая папка")
        precondition(FileNames.newFolder(existing: ["Новая папка", "Новая папка (2)", "Новая папка (4)"]) == "Новая папка (3)")
        let queue = FileOperationQueue()
        var order: [Int] = []
        queue.enqueue("one") { _ in try await Task.sleep(for: .milliseconds(10)); order.append(1) }
        queue.enqueue("two") { _ in order.append(2) }
        let third = queue.enqueue("three") { _ in order.append(3) }
        queue.cancel(third)
        while queue.busy { try await Task.sleep(for: .milliseconds(10)) }
        precondition(order == [1, 2] && third.state == .cancelled)
        queue.retry(third)
        while queue.busy { try await Task.sleep(for: .milliseconds(10)) }
        precondition(order == [1, 2, 3])
        let batch = UUID()
        let responder = Task { @MainActor in
            while queue.conflict == nil { try await Task.sleep(for: .milliseconds(5)) }
            queue.answerConflict(.overwriteAll)
        }
        let first = try await queue.resolve(FileConflict(name: "a", detail: "", allowsAll: true), batch: batch)
        let second = try await queue.resolve(FileConflict(name: "b", detail: "", allowsAll: true), batch: batch)
        precondition(first == .overwriteAll && second == .overwrite)
        _ = try await responder.value
        // Source changing during a copy must not be deleted or committed.
        let changing = from.appendingPathComponent("changing")
        try Data(repeating: 1, count: 1024 * 1024).write(to: changing)
        let altered = CancellationFlag()
        let mutating = FileTransferEngine(conflict: { _ in .overwrite }, progress: { _ in
            try? Data("changed".utf8).write(to: changing)
            altered.cancel()
        }, cancellation: altered)
        failed = false
        do { try await mutating.transfer(FileLocation(changing), to: FileLocation(to.appendingPathComponent("changing")), move: true) }
        catch { failed = true }
        precondition(failed && FileManager.default.fileExists(atPath: changing.path))
        // Observe the directory, not the file inode: editors commonly save by rename.
        let edits = root.appendingPathComponent("edits")
        let editorFolder = edits.appendingPathComponent("session")
        try FileManager.default.createDirectory(at: editorFolder, withIntermediateDirectories: true)
        let editingFile = editorFolder.appendingPathComponent("config.txt")
        try Data("initial".utf8).write(to: editingFile)
        let documents = RemoteDocuments(root: edits)
        var profile = ConnectionProfile(); profile.host = "example.com"
        let version = try await FileLocation(editingFile).metadata()!
        let session = try await documents.begin(profile: profile, remote: RemotePath("/config.txt").url, local: editingFile, version: version)
        let remoteURL = try RemotePath("/config.txt").url
        precondition(documents.existing(profile: profile, remoteURL: remoteURL) === session)
        var different = profile; different.transferProtocol = .s3; different.bucket = "other"
        precondition(documents.existing(profile: different, remoteURL: remoteURL) == nil, "Editing sessions must be isolated by protocol and bucket")
        var snapshots: [URL] = []
        documents.onSave = { _, url in snapshots.append(url) }
        try Data("saved atomically".utf8).write(to: editingFile, options: .atomic)
        for _ in 0..<50 {
            if !snapshots.isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        precondition(snapshots.count == 1, "An atomic editor save must trigger an upload snapshot")
        let savedContents = try Data(contentsOf: snapshots[0])
        precondition(savedContents == Data("saved atomically".utf8))
        documents.stop(session)
        precondition(FileManager.default.fileExists(atPath: editingFile.path))

    }
}
