import Foundation

protocol RemoteConnection: Sendable {
    func cancel()
    func contents(_ url: URL, showHidden: Bool) async throws -> DirectorySnapshot
    func metadata(_ path: RemotePath) async throws -> FileMetadata?
    func mkdir(_ path: RemotePath) async throws
    func remove(_ path: RemotePath, directory: Bool, expected: FileMetadata?) async throws
    func commit(_ source: RemotePath, to destination: RemotePath, overwrite: Bool, permissions: Int?, expectedDestination: FileMetadata?, cancellation: CancellationFlag) async throws
    func transfer(remote: RemotePath, local: URL, upload: Bool, cancellation: CancellationFlag,
                  progress: @escaping @Sendable (UInt64) -> Void) async throws -> UInt64
}

struct RemoteFileSystem: FileSystem {
    let connection: any RemoteConnection
    func contents(at url: URL, showHidden: Bool) async throws -> DirectorySnapshot {
        try await connection.contents(url, showHidden: showHidden)
    }
}
