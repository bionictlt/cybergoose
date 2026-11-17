import AppKit
import CryptoKit
import Observation
import Darwin

@MainActor @Observable
final class RemoteEditSession: Identifiable {
    let id = UUID()
    let profileID: String
    let endpoint: String
    let username: String
    let remoteURL: URL
    let localURL: URL
    var remoteVersion: FileMetadata
    var digest: Data
    var status = "Открыт в редакторе"
    var pending = false
    var watching = true
    init(profile: ConnectionProfile, remoteURL: URL, localURL: URL, remoteVersion: FileMetadata, digest: Data) {
        self.profileID = profile.id; self.endpoint = profile.resourceIdentity; self.username = profile.username; self.remoteURL = remoteURL; self.localURL = localURL; self.remoteVersion = remoteVersion; self.digest = digest
    }
}

private final class DirectoryWatcher {
    let source: DispatchSourceFileSystemObject
    init(url: URL, change: @escaping @Sendable () -> Void) throws {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .attrib], queue: .global(qos: .utility))
        source.setEventHandler(handler: change)
        source.setCancelHandler { close(fd) }
        source.resume()
    }
    deinit { source.cancel() }
}

@MainActor @Observable
final class RemoteDocuments {
    var sessions: [RemoteEditSession] = []
    var onSave: ((RemoteEditSession, URL) -> Void)?
    var onError: ((Error) -> Void)?
    private var watchers: [UUID: DirectoryWatcher] = [:]
    private var pending: [UUID: Task<Void, Never>] = [:]
    let root: URL
    init(root: URL = BookmarkStore().directory.appendingPathComponent("Editing", isDirectory: true)) { self.root = root }
    var hasPending: Bool { sessions.contains { $0.pending } || !pending.isEmpty }

    func existing(profile: ConnectionProfile, remoteURL: URL) -> RemoteEditSession? {
        sessions.first { $0.profileID == profile.id && $0.endpoint == profile.resourceIdentity && $0.username == profile.username && $0.remoteURL == remoteURL && $0.watching }
    }
    func begin(profile: ConnectionProfile, remote: URL, local: URL, version: FileMetadata) async throws -> RemoteEditSession {
        let digest = try await diskIO { try Self.hash(local) }
        let session = RemoteEditSession(profile: profile, remoteURL: remote, localURL: local, remoteVersion: version, digest: digest)
        // A recovery manifest contains no credentials and is kept beside the local copy.
        let manifest = ["host": profile.endpoint, "resource": profile.resourceIdentity, "protocol": profile.transferProtocol.rawValue, "bucket": profile.bucket, "user": profile.username, "remotePath": remote.path, "profileID": profile.id]
        try await diskIO {
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: local.deletingLastPathComponent().appendingPathExtension("json"), options: .atomic)
        }
        sessions.append(session)
        watchers[session.id] = try DirectoryWatcher(url: local.deletingLastPathComponent()) { [weak self] in
            Task { @MainActor in self?.changed(session.id) }
        }
        return session
    }
    func stop(_ session: RemoteEditSession) {
        watchers[session.id] = nil; pending[session.id]?.cancel(); pending[session.id] = nil
        session.watching = false; session.status = "Наблюдение остановлено; локальная копия сохранена"
    }
    private func changed(_ id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }), session.watching else { return }
        pending[id]?.cancel()
        pending[id] = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(700))
                guard let self else { return }
                let local = session.localURL
                let snapshotDirectory = root.appendingPathComponent("Snapshots/\(UUID())", isDirectory: true)
                let snapshot = snapshotDirectory.appendingPathComponent(local.lastPathComponent)
                let digest = try await diskIO {
                    let before = try local.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .fileResourceIdentifierKey])
                    try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try FileManager.default.copyItem(at: local, to: snapshot)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshot.path)
                    let digest = try Self.hash(snapshot)
                    let after = try local.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .fileResourceIdentifierKey])
                    guard before.contentModificationDate == after.contentModificationDate, before.fileSize == after.fileSize,
                          (before.fileResourceIdentifier as? NSObject) == (after.fileResourceIdentifier as? NSObject) else {
                        throw ClientError.message("Редактор ещё записывает файл; повторите сохранение.")
                    }
                    return digest
                }
                try Task.checkCancellation()
                if digest != session.digest {
                    session.digest = digest; session.pending = true; session.status = "Сохранение поставлено в очередь"
                    onSave?(session, snapshot)
                } else { try? FileManager.default.removeItem(at: snapshotDirectory) }
                pending[id] = nil
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled else { return }
                session.pending = true; session.status = "Ошибка: \(error.localizedDescription). Копия: \(session.localURL.path)"
                self?.pending[id] = nil
            }
        }
    }
    nonisolated static func hash(_ url: URL) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 262144), !data.isEmpty { hash.update(data: data) }
        return Data(hash.finalize())
    }
    func openEditor(_ url: URL) async throws {
        guard let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText) else { throw ClientError.message("Не найден редактор по умолчанию для текстовых файлов.") }
        let configuration = NSWorkspace.OpenConfiguration()
        try await NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: configuration)
    }
}
