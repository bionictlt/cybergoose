import Foundation
import CSSHBridge

struct SSHError: LocalizedError, Sendable {
    let message: String
    let connectionLost: Bool
    var errorDescription: String? { message }
}

// The C session is exclusively owned by this serial queue. Only cg_cancel is
// called concurrently; its socket access is protected by a C mutex.
final class SSHConnection: RemoteConnection, @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.cybergoose.ssh", qos: .userInitiated)
    private let handle: OpaquePointer
    private let useSCP: Bool
    init(useSCP: Bool = false) throws {
        self.useSCP = useSCP
        guard let handle = cg_create() else { throw ClientError.message("Не хватает памяти для SSH-сессии.") }
        self.handle = handle
    }
    deinit { cg_free(handle) }
    func cancel() { cg_cancel(handle) }
    func run<T: Sendable>(_ operation: @escaping @Sendable (OpaquePointer) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do { continuation.resume(returning: try operation(handle)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    private static func failure(_ handle: OpaquePointer) -> SSHError {
        SSHError(message: String(cString: cg_error(handle)), connectionLost: cg_connection_failed(handle) != 0)
    }
    private static func check(_ code: Int32, _ handle: OpaquePointer) throws {
        guard code >= 0 else { throw Self.failure(handle) }
    }
    func handshake(_ profile: ConnectionProfile) async throws -> HostIdentity {
        try await run { handle in
            try Self.check(cg_handshake(handle, profile.host, Int32(profile.port)), handle)
            var length = 0
            var type: Int32 = 0
            guard let key = cg_hostkey(handle, &length, &type), length > 0 else { throw ClientError.message("Сервер не предоставил SSH host key.") }
            let algorithms: [Int32: String] = [1: "RSA", 2: "DSS", 3: "ECDSA P-256", 4: "ECDSA P-384", 5: "ECDSA P-521", 6: "Ed25519"]
            return HostIdentity(key: Data(bytes: key, count: length), algorithm: algorithms[type] ?? "SSH key \(type)")
        }
    }
    func authenticate(_ profile: ConnectionProfile, secret: String) async throws -> RemotePath {
        try await run { handle in
            try Self.check(cg_auth(handle, profile.username, secret, profile.authentication == .privateKey ? profile.privateKeyPath : ""), handle)
            return try Self.realpath(profile.initialPath, handle: handle)
        }
    }
    private static func realpath(_ path: String, handle: OpaquePointer) throws -> RemotePath {
        var buffer = [CChar](repeating: 0, count: 32768)
        let length = cg_realpath(handle, path, &buffer, buffer.count)
        try check(length, handle)
        guard let string = String(bytes: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, encoding: .utf8) else {
            throw ClientError.message("Сервер вернул путь не в UTF-8.")
        }
        return try RemotePath(string)
    }
    func contents(_ url: URL, showHidden: Bool) async throws -> DirectorySnapshot {
        try await run { handle in
            let path = try Self.realpath(url.path, handle: handle)
            guard let directory = cg_opendir(handle, path.value) else { throw Self.failure(handle) }
            defer { cg_closedir(handle, directory) }
            var entries: [FileEntry] = []
            var nameBuffer = [CChar](repeating: 0, count: 32768)
            while true {
                var attrs = cg_attrs()
                let count = cg_readdir(handle, directory, &nameBuffer, nameBuffer.count, &attrs)
                try Self.check(count, handle)
                if count == 0 { break }
                guard Int(count) < nameBuffer.count - 1,
                      let name = String(bytes: nameBuffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }, encoding: .utf8) else {
                    throw ClientError.message("Имя файла слишком длинное или имеет неподдерживаемую кодировку (нужен UTF-8).")
                }
                if name == "." || name == ".." || (!showHidden && name.hasPrefix(".")) { continue }
                let child = try path.child(name)
                let hasPermissions = attrs.flags & 4 != 0
                let directory = hasPermissions && attrs.permissions & 0o170000 == 0o040000
                let symlink = hasPermissions && attrs.permissions & 0o170000 == 0o120000
                entries.append(FileEntry(url: child.url, name: name, isDirectory: directory, isSymbolicLink: symlink,
                    size: attrs.flags & 1 != 0 && !directory ? Int64(clamping: attrs.size) : nil,
                    modified: attrs.flags & 8 != 0 ? Date(timeIntervalSince1970: Double(attrs.modified)) : nil,
                    type: directory ? "Папка" : (symlink ? "Ссылка" : "Файл")))
            }
            return DirectorySnapshot(url: path.url, entries: entries)
        }
    }
    func mkdir(_ path: RemotePath) async throws { try await run { try Self.check(cg_mkdir($0, path.value), $0) } }
    func rename(_ source: RemotePath, to destination: RemotePath) async throws {
        try await run { try Self.check(cg_rename($0, source.value, destination.value), $0) }
    }
    func remove(_ path: RemotePath, directory: Bool, expected: FileMetadata? = nil) async throws {
        try await run { try Self.check(cg_remove($0, path.value, directory ? 1 : 0), $0) }
    }
    func metadata(_ path: RemotePath) async throws -> FileMetadata? {
        try await run { handle in
            var attrs = cg_attrs()
            let result = cg_stat(handle, path.value, &attrs)
            try Self.check(result, handle)
            if result == 1 { return nil }
            guard attrs.flags & 4 != 0 else { throw ClientError.message("Сервер не вернул тип файла.") }
            let kind: FileMetadata.Kind = attrs.permissions & 0o170000 == 0o040000 ? .directory : (attrs.permissions & 0o170000 == 0o120000 ? .symlink : .file)
            return FileMetadata(kind: kind, size: attrs.flags & 1 != 0 ? Int64(clamping: attrs.size) : nil,
                modified: attrs.flags & 8 != 0 ? Double(attrs.modified) : nil, permissions: Int(attrs.permissions & 0o777), identity: nil)
        }
    }
    func commit(_ temporary: RemotePath, to destination: RemotePath, overwrite: Bool, permissions: Int?, expectedDestination: FileMetadata? = nil, cancellation: CancellationFlag = CancellationFlag()) async throws {
        try cancellation.check()
        try await run { try Self.check(cg_commit($0, temporary.value, destination.value, overwrite ? 1 : 0, permissions ?? -1), $0) }
    }

    func transfer(remote: RemotePath, local: URL, upload: Bool, cancellation: CancellationFlag = CancellationFlag(), progress: @escaping @Sendable (UInt64) -> Void) async throws -> UInt64 {
        try await run { handle in
            var bytes: UInt64 = 0
            try cancellation.check()
            let box = ProgressCallback(cancellation: cancellation, callback: progress)
            let pointer = Unmanaged.passUnretained(box).toOpaque()
            let transfer = self.useSCP ? cg_scp_transfer : cg_transfer
            let result = transfer(handle, remote.value, local.path, upload ? 1 : 0, { bytes, context in
                guard let context else { return 1 }
                return Unmanaged<ProgressCallback>.fromOpaque(context).takeUnretainedValue().report(bytes)
            }, pointer, &bytes)
            withExtendedLifetime(box) {}
            try cancellation.check()
            try Self.check(result, handle)
            return bytes
        }
    }
}

private final class ProgressCallback {
    let callback: @Sendable (UInt64) -> Void
    private var lastReport = Date.distantPast
    let cancellation: CancellationFlag
    init(cancellation: CancellationFlag, callback: @escaping @Sendable (UInt64) -> Void) { self.cancellation = cancellation; self.callback = callback }
    func report(_ bytes: UInt64) -> Int32 {
        do { try cancellation.check() } catch { return 1 }
        let now = Date()
        if now.timeIntervalSince(lastReport) > 0.1 { lastReport = now; callback(bytes) }
        return 0
    }
}

struct SFTPFileSystem: FileSystem {
    let connection: SSHConnection
    func contents(at url: URL, showHidden: Bool) async throws -> DirectorySnapshot {
        try await connection.contents(url, showHidden: showHidden)
    }
}
