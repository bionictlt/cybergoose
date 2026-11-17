import AppKit
import SwiftUI
import Observation

// Test double for the network connection lifecycle. All file operations, queue,
// workspace logic and table delegates below are the production implementations.
@MainActor @Observable final class ConnectionManager {
    enum State: String { case disconnected = "Нет подключения", connected = "Тестовое подключение" }
    var state = State.disconnected
    var profile: ConnectionProfile?
    var connection: (any RemoteConnection)?
    var trustRequest: HostTrustRequest?
    var busy: Bool { false }
    var onConnected: ((ConnectionProfile, any RemoteConnection, RemotePath) -> Void)?
    var onDisconnected: (() -> Void)?
    var onError: ((Error) -> Void)?
    func connect(_ profile: ConnectionProfile, secret: String) {}
    func answerTrust(_ accept: Bool, remember: Bool = false) {}
    func disconnect() { state = .disconnected; connection = nil; profile = nil; onDisconnected?() }
    func attach(_ connection: any RemoteConnection) throws {
        var profile = ConnectionProfile(); profile.host = "drag-test.invalid"
        self.profile = profile; self.connection = connection; state = .connected
        onConnected?(profile, connection, try RemotePath("/"))
    }
}

final class DiskRemote: RemoteConnection, Sendable {
    let root: URL
    init(root: URL) { self.root = root }
    func cancel() {}
    func local(_ path: RemotePath) -> URL { root.appendingPathComponent(String(path.value.dropFirst())) }
    func contents(_ url: URL, showHidden: Bool) async throws -> DirectorySnapshot {
        let path = try RemotePath(url.path)
        let listing = try await LocalFileSystem().contents(at: local(path), showHidden: showHidden)
        return DirectorySnapshot(url: path.url, entries: try listing.entries.map {
            FileEntry(url: try path.child($0.name).url, name: $0.name, isDirectory: $0.isDirectory,
                      isSymbolicLink: $0.isSymbolicLink, size: $0.size, modified: $0.modified, type: $0.type)
        })
    }
    func metadata(_ path: RemotePath) async throws -> FileMetadata? { try await FileLocation(local(path)).metadata() }
    func mkdir(_ path: RemotePath) async throws { try await FileLocation(local(path)).mkdir() }
    func remove(_ path: RemotePath, directory: Bool, expected: FileMetadata?) async throws { try await FileLocation(local(path)).remove(directory: directory, expected: expected) }
    func commit(_ source: RemotePath, to destination: RemotePath, overwrite: Bool, permissions: Int?, expectedDestination: FileMetadata?, cancellation: CancellationFlag) async throws {
        try await FileLocation(local(source)).commit(to: FileLocation(local(destination)), overwrite: overwrite, permissions: permissions, expectedDestination: expectedDestination, cancellation: cancellation)
    }
    func transfer(remote: RemotePath, local: URL, upload: Bool, cancellation: CancellationFlag, progress: @escaping @Sendable (UInt64) -> Void) async throws -> UInt64 {
        let engine = FileTransferEngine(conflict: { _ in throw ClientError.message("Existing staging destination") }, progress: progress, cancellation: cancellation)
        let remoteFile = self.local(remote)
        try await engine.transfer(FileLocation(upload ? local : remoteFile), to: FileLocation(upload ? remoteFile : local), move: false)
        return UInt64(try await FileLocation(upload ? remoteFile : local).metadata()!.size!)
    }
}

@MainActor final class TestDraggingInfo: NSObject, NSDraggingInfo {
    let draggingSource: Any?
    let draggingPasteboard: NSPasteboard
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 3
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(source: CommanderTable) {
        draggingSource = source
        draggingPasteboard = NSPasteboard.withUniqueName()
        super.init()

    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}

@main struct DragDropChecks {
    @MainActor static func idle(_ workspace: WorkspaceModel) async throws {
        for _ in 0..<1000 {
            if !workspace.queue.busy && !workspace.local.loading && workspace.remote?.loading != true { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ClientError.message("Test timed out")
    }
    @MainActor static func setup(_ root: URL) async throws -> (WorkspaceModel, DiskRemote, URL, URL) {
        let local = root.appendingPathComponent("local"), remote = root.appendingPathComponent("remote")
        for folder in [local, remote, local.appendingPathComponent("folder/nested")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data("first payload".utf8).write(to: local.appendingPathComponent("one.txt"))
        try Data("second payload".utf8).write(to: local.appendingPathComponent("two.txt"))
        try Data("nested payload".utf8).write(to: local.appendingPathComponent("folder/nested/child.txt"))
        let workspace = WorkspaceModel(), connection = DiskRemote(root: remote)
        workspace.local.navigate(to: local, showHidden: true)
        try workspace.connections.attach(connection)
        try await idle(workspace)
        return (workspace, connection, local, remote)
    }
    @MainActor static func check() async throws {
        let root = try CurlTransport.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (workspace, connection, local, remote) = try await setup(root)
        let entries = workspace.local.entries
        // Parent navigation stays first even for descending/non-name sorting.
        for panel in [workspace.local, workspace.remote!] {
            for sort in FileSort.allCases {
                for ascending in [true, false] {
                    panel.sort = sort; panel.ascending = ascending
                    precondition(panel.sortedEntries.first?.name == ".." && panel.sortedEntries.first?.isParent == true)
                    precondition(panel.sortedEntries.count == panel.entries.count + 1)
                }
            }
            panel.sort = .name; panel.ascending = true
        }
        workspace.activePanel = .local
        workspace.remote!.selection = Set(workspace.remote!.entries.map(\.id))
        let previousFocus = workspace.remote!.focusRequest
        workspace.togglePanel()
        precondition(workspace.activePanel == .remote && workspace.remote!.selection == [workspace.remote!.parentEntry.id])
        precondition(workspace.remote!.focusRequest != previousFocus)
        workspace.confirmDelete(); precondition(workspace.deletion == nil)
        workspace.togglePanel()
        precondition(workspace.activePanel == .local && workspace.local.selection == [workspace.local.parentEntry.id])
        precondition(workspace.local.selectedEntries.isEmpty && workspace.local.selectedSize == 0)
        workspace.copySelection(); precondition(workspace.queue.jobs.isEmpty)
        workspace.requestRename(workspace.local.parentEntry, side: .local)
        workspace.rename(workspace.local.parentEntry, side: .local, to: "renamed-parent")
        precondition(workspace.renameRequest == nil && workspace.queue.jobs.isEmpty)
        precondition(workspace.beginFileDrag([workspace.local.parentEntry], from: .local) == nil)
        workspace.local.navigate(to: local.appendingPathComponent("folder"), showHidden: true)
        try await idle(workspace)
        workspace.open(workspace.local.parentEntry, side: .local)
        try await idle(workspace)
        precondition(workspace.local.path.standardizedFileURL.path == local.standardizedFileURL.path)
        // Select-all includes the navigation row visually, but file operations don't.
        workspace.local.selection = Set(workspace.local.sortedEntries.map(\.id))
        precondition(workspace.local.selectedEntries.count == entries.count)
        let rootPanel = PanelModel(path: URL(fileURLWithPath: "/"), fileSystem: LocalFileSystem())
        precondition(rootPanel.sortedEntries.first?.isParent == true)
        let drag = workspace.beginFileDrag(workspace.local.sortedEntries, from: .local)!
        precondition(workspace.canDropFiles(drag, to: .remote))
        precondition(!workspace.canDropFiles(drag, to: .local))
        workspace.remote!.loading = true
        precondition(!workspace.canDropFiles(drag, to: .remote)); workspace.remote!.loading = false
        let other = WorkspaceModel(); precondition(!other.canDropFiles(drag, to: .remote))
        // Selection and active side can change while dragging. The frozen source
        // rows must still be copied, rather than using the destination selection.
        workspace.local.selection = []; workspace.activePanel = .remote
        let sourceTable = CommanderTable(), destinationTable = CommanderTable()
        sourceTable.panelDrag = drag
        let drop = TestDraggingInfo(source: sourceTable)
        let destinationCoordinator = FileTableView.Coordinator(model: workspace.remote!, workspace: workspace, side: .remote)
        // Exercise the real AppKit callbacks with an empty destination table.
        precondition(destinationCoordinator.tableView(destinationTable, validateDrop: drop, proposedRow: 0, proposedDropOperation: .above) == .copy)
        precondition(destinationCoordinator.tableView(sourceTable, validateDrop: drop, proposedRow: 0, proposedDropOperation: .on).isEmpty)
        precondition(destinationCoordinator.tableView(destinationTable, acceptDrop: drop, row: -1, dropOperation: .on))
        let batch = workspace.queue.jobs.map(\.batch)
        precondition(batch.count == 3 && Set(batch).count == 1)
        try await idle(workspace)
        precondition(workspace.queue.jobs.allSatisfy { $0.state == .done })
        for relative in ["one.txt", "two.txt", "folder/nested/child.txt"] {
            let original = try Data(contentsOf: local.appendingPathComponent(relative))
            let copied = try Data(contentsOf: remote.appendingPathComponent(relative))
            precondition(original == copied, "Drag must recursively copy without deleting the source")
        }
        let download = root.appendingPathComponent("download")
        try FileManager.default.createDirectory(at: download, withIntermediateDirectories: true)
        workspace.local.navigate(to: download, showHidden: true); try await idle(workspace)
        let reverse = workspace.beginFileDrag(workspace.remote!.entries, from: .remote)!
        workspace.activePanel = .local
        precondition(workspace.dropFiles(reverse, to: .local)); try await idle(workspace)
        let received = try Data(contentsOf: download.appendingPathComponent("folder/nested/child.txt"))
        precondition(received == Data("nested payload".utf8))
        // A second drop uses the same conflict handling and overwrite-all batch as F5.
        let conflictDrag = workspace.beginFileDrag(entries, from: .local)!
        let conflicts = Task { @MainActor in
            while workspace.queue.conflict == nil { try await Task.sleep(for: .milliseconds(10)) }
            workspace.queue.answerConflict(.overwriteAll)
        }
        precondition(workspace.dropFiles(conflictDrag, to: .remote))
        try await conflicts.value; try await idle(workspace)
        precondition(workspace.queue.jobs.allSatisfy { $0.state == .done })
        let stale = workspace.beginFileDrag(entries, from: .local)!
        workspace.disconnect()
        precondition(!workspace.dropFiles(stale, to: .remote))
        try workspace.connections.attach(connection); try await idle(workspace)
        precondition(!workspace.dropFiles(stale, to: .remote), "Reconnect must invalidate a drag")
        // Real table data source: private pasteboard items, no file URLs exported.
        let coordinator = FileTableView.Coordinator(model: workspace.local, workspace: workspace, side: .local)
        coordinator.rows = workspace.local.sortedEntries
        let table = CommanderTable()
        precondition(coordinator.tableView(table, pasteboardWriterForRow: 0) == nil)
        coordinator.rows = entries
        let writer = coordinator.tableView(table, pasteboardWriterForRow: 0) as! NSPasteboardItem
        precondition(writer.types == [CommanderTable.panelEntriesType])
        coordinator.editingURL = entries[0].url
        precondition(coordinator.tableView(table, pasteboardWriterForRow: 0) == nil)
    }
    @MainActor static func main() async {
        do {
            try await check()
            print("Passed: drag snapshots, copy in both directions, nested folders, source preservation, conflict batch, loading/disconnect/reconnect guards, private pasteboard, native validateDrop/acceptDrop, Tab focus, pinned parent row and safe parent navigation")
        } catch { print("Drag checks failed: \(error)"); exit(1) }
    }
}
