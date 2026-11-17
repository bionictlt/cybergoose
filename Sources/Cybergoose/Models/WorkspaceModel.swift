import AppKit
import Observation

struct DeletionRequest: Identifiable {
    let id = UUID()
    let entries: [FileEntry]
    let connection: any RemoteConnection
}

@MainActor @Observable
final class WorkspaceModel {
    let local = PanelModel(path: FileManager.default.homeDirectoryForCurrentUser, fileSystem: LocalFileSystem())
    var remote: PanelModel?
    let connections = ConnectionManager()
    var profiles: [ConnectionProfile] = []
    var selectedBookmark: String?
    var activePanel: PanelSide = .local
    var showHidden = false
    var errorMessage: String?
    var connectionDraft: ConnectionProfile?
    var draftSecret = ""
    var draftRemember = false
    var draftWarning: String?
    var deletion: DeletionRequest?
    var showNamePrompt = false
    var proposedName = ""
    let queue = FileOperationQueue()
    let documents = RemoteDocuments()
    private let quickLook = QuickLookController()
    var showQueue = false
    var renameRequest: RenameRequest?
    var nameSide = PanelSide.local
    var nameDirectory: URL?
    var operationTitle: String? { queue.running?.title }
    var transferred: UInt64 { queue.running?.bytes ?? 0 }
    var transferTotal: Int64 { queue.running?.total ?? 0 }
    private var pendingConnection: (ConnectionProfile, String)?
    private let bookmarks = BookmarkStore()
    private let dragWorkspaceID = UUID()
    private var dragConnectionID = UUID()
    var active: PanelModel? { activePanel == .local ? local : remote }
    var isOperating: Bool { queue.busy }
    var canConnect: Bool { !connections.busy && !isOperating && selectedProfile != nil }
    var selectedProfile: ConnectionProfile? { profiles.first { $0.id == selectedBookmark } }
    var connectionStatus: String {
        connections.state == .connected ? "\(connections.profile?.transferProtocol.title ?? "") · \(connections.profile?.endpoint ?? "")" : connections.state.rawValue
    }
    init() {
        do { profiles = try bookmarks.load(); selectedBookmark = profiles.first?.id }
        catch { errorMessage = error.localizedDescription }
        queue.onChange = { [weak self] in self?.refreshBoth() }
        queue.onFailure = { [weak self] error in
            if let ssh = error as? SSHError, ssh.connectionLost { self?.report(error) }
        }
        documents.onSave = { [weak self] session, snapshot in self?.uploadEdit(session, snapshot: snapshot) }
        local.errorHandler = { [weak self] in self?.report($0) }
        connections.onError = { [weak self] in self?.report($0) }
        connections.onConnected = { [weak self] _, connection, path in
            guard let self else { return }
            dragConnectionID = UUID()
            let panel = PanelModel(path: path.url, fileSystem: RemoteFileSystem(connection: connection))
            panel.errorHandler = { [weak self] in self?.report($0) }
            remote = panel; activePanel = .remote
            panel.navigate(to: path.url, showHidden: showHidden)
        }
        connections.onDisconnected = { [weak self] in
            guard let self else { return }
            dragConnectionID = UUID()
            remote?.stop(); remote = nil
        }
    }
    func report(_ error: Error) {
        if let ssh = error as? SSHError, ssh.connectionLost { disconnect() }
        errorMessage = error.localizedDescription
    }
    func start() { local.navigate(to: local.path, showHidden: showHidden) }
    func refresh() { if let active { active.navigate(to: active.path, showHidden: showHidden) } }
    func refreshBoth() {
        local.navigate(to: local.path, showHidden: showHidden)
        if let remote { remote.navigate(to: remote.path, showHidden: showHidden) }
    }
    func home() { activePanel = .local; local.navigate(to: FileManager.default.homeDirectoryForCurrentUser, showHidden: showHidden) }
    func parent(_ side: PanelSide) {
        guard let panel = side == .local ? local : remote else { return }
        if side == .remote {
            let path = panel.path.path
            let parent = path == "/" ? "/" : (connections.profile?.transferProtocol.isSSH == true ? path + "/.." : panel.path.deletingLastPathComponent().path)
            do { panel.navigate(to: try RemotePath(parent).url, showHidden: showHidden) } catch { report(error) }
        } else { panel.navigate(to: panel.path.deletingLastPathComponent(), showHidden: showHidden) }
    }
    func submitPath(_ side: PanelSide) {
        guard let panel = side == .local ? local : remote else { return }
        do {
            let url = side == .local ? URL(fileURLWithPath: NSString(string: panel.pathText).expandingTildeInPath) : try RemotePath(panel.pathText).url
            panel.navigate(to: url, showHidden: showHidden)
        } catch { report(error) }
    }
    func open(_ entry: FileEntry, side: PanelSide) {
        if entry.isParent { parent(side); return }
        if entry.isDirectory || (side == .remote && entry.isSymbolicLink) {
            (side == .local ? local : remote)?.navigate(to: entry.url, showHidden: showHidden)
        } else { openFile(entry, side: side, mode: .defaultApplication) }
    }
    func togglePanel() {
        activePanel = activePanel == .local ? .remote : .local
        if let active { active.focusFirstEntry() }
        else { selectedBookmark = profiles.first?.id }
    }
    func newConnection() { draftSecret = ""; draftRemember = false; draftWarning = nil; connectionDraft = ConnectionProfile() }
    func editConnection(_ profile: ConnectionProfile) {
        Task {
            do {
                let secret = try await Task.detached { try CredentialStore().read(profile.id) }.value
                draftSecret = secret ?? ""; draftRemember = secret != nil; draftWarning = nil; connectionDraft = profile
            } catch { showDraftWithoutKeychain(profile, error: error) }
        }
    }
    private func showDraftWithoutKeychain(_ profile: ConnectionProfile, error: Error) {
        draftSecret = ""; draftRemember = false
        draftWarning = "Keychain недоступен: \(error.localizedDescription) Можно ввести секрет для этого подключения без сохранения."
        connectionDraft = profile
    }
    func beginConnect() {
        guard let profile = selectedProfile, !connections.busy, !isOperating else { return }
        Task {
            do {
                let secret = try await Task.detached { try CredentialStore().read(profile.id) }.value
                if let secret { connections.connect(try profile.validated(), secret: secret) }
                else { draftSecret = ""; draftRemember = false; draftWarning = nil; connectionDraft = profile }
            } catch { showDraftWithoutKeychain(profile, error: error) }
        }
    }
    func connectionEditorDismissed() {
        draftSecret = ""; draftRemember = false; draftWarning = nil
        if let (profile, secret) = pendingConnection {
            pendingConnection = nil
            connections.connect(profile, secret: secret)
        }
    }
    func saveConnection(_ profile: ConnectionProfile, secret: String, remember: Bool, connect: Bool) async throws {
        guard !connect || !isOperating else { throw ClientError.message("Сначала дождитесь завершения передачи или отмените её.") }
        let profile = try profile.validated()
        if !remember, draftWarning != nil, profiles.contains(where: { $0.id == profile.id }) {
            guard connect else { throw ClientError.message("Keychain недоступен: нельзя изменить закладку и гарантированно удалить её прежний секрет. Можно подключиться с введёнными параметрами без сохранения изменений.") }
            pendingConnection = (profile, secret); connectionDraft = nil
            return
        }
        var updated = profiles
        if let index = updated.firstIndex(where: { $0.id == profile.id }) { updated[index] = profile }
        else { updated.append(profile) }
        // Credential access may prompt the system; keep it off MainActor.
        let forgetStoredSecret = draftRemember || (profiles.contains { $0.id == profile.id } && draftWarning == nil)
        try await Task.detached {
            if remember { try CredentialStore().save(secret, id: profile.id) }
            else if forgetStoredSecret { try CredentialStore().delete(profile.id) }
        }.value
        try bookmarks.save(updated)
        profiles = updated; selectedBookmark = profile.id
        if connect { pendingConnection = (profile, secret) }
        connectionDraft = nil
    }
    func deleteBookmark(_ profile: ConnectionProfile) {
        Task {
            do {
                let updated = profiles.filter { $0.id != profile.id }
                try await Task.detached { try CredentialStore().delete(profile.id) }.value
                try bookmarks.save(updated); profiles = updated; selectedBookmark = updated.first?.id
            } catch { report(error) }
        }
    }
    func disconnect() {
        queue.cancelAll()
        connections.disconnect()
    }
    func location(_ entry: FileEntry, side: PanelSide) -> FileLocation { FileLocation(entry.url, connection: side == .remote ? connections.connection : nil) }
    func requestRename(_ entry: FileEntry? = nil, side: PanelSide? = nil) {
        let side = side ?? activePanel
        guard let panel = side == .local ? local : remote else { return }
        guard let entry = entry ?? (panel.selectedEntries.count == 1 ? panel.selectedEntries.first : nil) else { return }
        guard !entry.isParent else { return }
        activePanel = side
        renameRequest = RenameRequest(url: entry.url, side: side)
    }
    func rename(_ entry: FileEntry, side: PanelSide, to name: String) {
        guard !entry.isParent else { return }
        do {
            try RemotePath.validateName(name)
            guard name != entry.name else { return }
            let source = location(entry, side: side)
            let target = try source.parent.child(name)
            queue.enqueue("Переименовать «\(entry.name)»") { job in
                try job.cancellation.check()
                guard try await target.metadata() == nil else { throw ClientError.message("Имя «\(name)» уже занято.") }
                try await source.commit(to: target, overwrite: false, permissions: nil)
                (side == .local ? self.local : self.remote)?.selection = [target.url]
            }
        } catch { report(error) }
    }
    func promptName(rename: Bool) {
        if rename { requestRename(); return }
        guard let panel = active, !panel.loading else { return }
        let side = activePanel; let directory = panel.path
        Task {
            do {
                let entries = try await panel.fileSystem.contents(at: directory, showHidden: true).entries
                proposedName = FileNames.newFolder(existing: Set(entries.map(\.name)))
                nameSide = side; nameDirectory = directory; showNamePrompt = true
            } catch { report(error) }
        }
    }
    func applyName() {
        guard let directory = nameDirectory else { return }
        do {
            let folder = try FileLocation(directory, connection: nameSide == .remote ? connections.connection : nil).child(proposedName)
            queue.enqueue("Создать «\(proposedName)»") { job in
                try job.cancellation.check(); try await folder.mkdir()
            }
        } catch { report(error) }
    }
    func confirmDelete() {
        guard activePanel == .remote, let remote, let connection = connections.connection, !remote.selectedEntries.isEmpty else { return }
        deletion = DeletionRequest(entries: remote.selectedEntries, connection: connection)
    }
    func delete(_ request: DeletionRequest) {
        queue.enqueue("Удаление \(request.entries.count) объектов") { job in
            for entry in request.entries {
                try job.cancellation.check()
                try await request.connection.remove(try RemotePath(entry.url.path), directory: entry.isDirectory && !entry.isSymbolicLink, expected: nil)
            }
        }
    }
    func engine(for job: QueuedOperation) -> FileTransferEngine {
        FileTransferEngine(conflict: { [queue, batch = job.batch] conflict in
            try await queue.resolve(conflict, batch: batch)
        }, progress: { [weak job] bytes in
            Task { @MainActor in if job?.state == .running { job?.bytes = bytes } }
        }, cancellation: job.cancellation)
    }
    // Freeze the actual dragged rows, not the selection or active panel at drop time.
    struct PanelDrag {
        let workspaceID: UUID
        let connectionID: UUID
        let source: PanelSide
        let entries: [FileEntry]
    }
    func canDragFiles(from side: PanelSide) -> Bool {
        guard connections.state == .connected, connections.connection != nil, connections.profile != nil,
              let remote else { return false }
        return !(side == .local ? local : remote).loading
    }
    func beginFileDrag(_ entries: [FileEntry], from side: PanelSide) -> PanelDrag? {
        let entries = entries.filter { !$0.isParent }
        guard canDragFiles(from: side), !entries.isEmpty else { return nil }
        return PanelDrag(workspaceID: dragWorkspaceID, connectionID: dragConnectionID, source: side, entries: entries)
    }
    func canDropFiles(_ drag: PanelDrag, to side: PanelSide) -> Bool {
        guard drag.workspaceID == dragWorkspaceID, drag.connectionID == dragConnectionID,
              drag.source != side, !drag.entries.isEmpty,
              connections.state == .connected, connections.connection != nil, connections.profile != nil,
              let destination = side == .local ? local : remote else { return false }
        return !destination.loading
    }
    @discardableResult
    func dropFiles(_ drag: PanelDrag, to side: PanelSide) -> Bool {
        guard canDropFiles(drag, to: side), let destination = side == .local ? local : remote,
              let profile = connections.profile else { return false }
        enqueueTransfer(drag.entries, from: drag.source, to: destination.path, profile: profile, move: false)
        activePanel = side
        return true
    }
    func copySelection(move: Bool = false) {
        guard let profile = connections.profile, connections.connection != nil, let remote, let source = active else { return }
        let destination = activePanel == .local ? remote.path : local.path
        enqueueTransfer(source.selectedEntries, from: activePanel, to: destination, profile: profile, move: move)
    }
    private func enqueueTransfer(_ entries: [FileEntry], from side: PanelSide, to destinationURL: URL,
                                 profile: ConnectionProfile, move: Bool) {
        let batch = UUID()
        for entry in entries where !entry.isParent {
            queue.enqueue("\(move ? "Переместить" : "Копировать") «\(entry.name)»", batch: batch) { [weak self] job in
                guard let self else { return }
                guard connections.profile?.id == profile.id, connections.profile?.resourceIdentity == profile.resourceIdentity,
                      connections.profile?.username == profile.username, let connection = connections.connection else {
                    throw ClientError.message("Подключитесь к исходному серверу и повторите задание.")
                }
                let origin = FileLocation(entry.url, connection: side == .remote ? connection : nil)
                let destination = FileLocation(destinationURL, connection: side == .local ? connection : nil)
                job.total = entry.size ?? 0
                try await engine(for: job).transfer(origin, to: destination.child(entry.name), move: move)
            }
        }
    }

    enum OpenMode { case preview, defaultApplication, textEditor }
    func previewSelection() {
        guard let entry = active?.selectedEntries.first else { return }
        openFile(entry, side: activePanel, mode: .preview)
    }
    func editSelection() {
        guard let entry = active?.selectedEntries.first else { return }
        openFile(entry, side: activePanel, mode: .textEditor)
    }
    func openFile(_ entry: FileEntry, side: PanelSide, mode: OpenMode) {
        guard !entry.isDirectory, !entry.isSymbolicLink else { return }
        if side == .local {
            if mode == .preview { quickLook.show(entry.url) }
            else if mode == .textEditor { Task { do { try await documents.openEditor(entry.url) } catch { report(error) } } }
            else { NSWorkspace.shared.open(entry.url) }
            return
        }
        guard let connection = connections.connection, let profile = connections.profile else { return }
        if mode == .textEditor, let existing = documents.existing(profile: profile, remoteURL: entry.url) {
            Task { do { try await documents.openEditor(existing.localURL) } catch { report(error) } }; return
        }
        queue.enqueue("Открыть «\(entry.name)»") { [weak self] job in
            guard let self else { return }
            let directory = documents.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try await diskIO { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            let localURL = directory.appendingPathComponent(entry.name)
            let source = FileLocation(entry.url, connection: connection)
            guard let version = try await source.metadata() else { throw ClientError.message("Удалённый файл исчез.") }
            job.total = entry.size ?? 0
            try await engine(for: job).transfer(source, to: FileLocation(localURL), move: false)
            try job.cancellation.check()
            if mode == .textEditor {
                try await diskIO { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: localURL.path) }
                _ = try await documents.begin(profile: profile, remote: entry.url, local: localURL, version: version)
                try await documents.openEditor(localURL)
            } else if mode == .preview { quickLook.show(localURL) }
            else { NSWorkspace.shared.open(localURL) }
        }
    }
    private func uploadEdit(_ session: RemoteEditSession, snapshot: URL) {
        let savedDigest = session.digest
        queue.enqueue("Сохранить на сервер «\(session.remoteURL.lastPathComponent)»") { [weak self, weak session] job in
            guard let self, let session else { return }
            do {
                guard connections.profile?.id == session.profileID, connections.profile?.resourceIdentity == session.endpoint, connections.profile?.username == session.username, let connection = connections.connection else {
                    throw ClientError.message("Подключитесь к исходному серверу и повторите задание. Локальная копия: \(session.localURL.path)")
                }
                let destination = FileLocation(session.remoteURL, connection: connection)
                let uploaded = try await engine(for: job).transfer(FileLocation(snapshot), to: destination, move: false,
                    expectedDestination: session.remoteVersion, allowExpectedOverwrite: true)
                if uploaded, let version = try await destination.metadata() {
                    session.remoteVersion = version; session.pending = session.digest != savedDigest
                    session.status = session.pending ? "Есть более новая версия в очереди" : "Изменения отправлены на сервер"
                    try? await diskIO { try FileManager.default.removeItem(at: snapshot.deletingLastPathComponent()) }
                } else { session.status = "Отправка пропущена; локальная копия сохранена" }
            } catch {
                session.pending = true; session.status = "Не отправлено: \(error.localizedDescription)"
                throw error
            }
        }
    }
    func perform(_ key: Int) {
        switch key {
        case 3: previewSelection()
        case 4: editSelection()
        case 5: copySelection()
        case 6: copySelection(move: true)
        case 7: promptName(rename: false)
        case 8: confirmDelete()
        case 10: if connections.state != .disconnected { disconnect() } else { NSApp.keyWindow?.performClose(nil) }
        default: break
        }
    }
}

struct RenameRequest {
    let id = UUID()
    let url: URL
    let side: PanelSide
}
