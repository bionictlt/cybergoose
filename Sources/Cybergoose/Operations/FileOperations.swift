import Foundation
import Darwin

func diskIO<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await Task.detached(priority: .utility, operation: body).value
}

struct FileLocation: Sendable {
    let url: URL
    let connection: (any RemoteConnection)?
    init(_ url: URL, connection: (any RemoteConnection)? = nil) { self.url = url; self.connection = connection }
    private func validate() throws {
        guard connection != nil || url.isFileURL else {
            throw ClientError.message("Удалённое соединение закрыто. Операция не будет выполняться в локальной файловой системе.")
        }
    }
    func child(_ name: String) throws -> Self {
        try validate()
        try RemotePath.validateName(name)
        return Self(connection == nil ? url.appendingPathComponent(name) : try RemotePath(url.path).child(name).url, connection: connection)
    }
    var parent: Self { Self(url.deletingLastPathComponent(), connection: connection) }
    func metadata() async throws -> FileMetadata? {
        try validate()
        if let connection { return try await connection.metadata(RemotePath(url.path)) }
        return try await diskIO {
            var info = stat()
            let result = url.withUnsafeFileSystemRepresentation { lstat($0!, &info) }
            if result != 0 {
                if errno == ENOENT { return nil }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let kind: FileMetadata.Kind = info.st_mode & S_IFMT == S_IFDIR ? .directory : (info.st_mode & S_IFMT == S_IFLNK ? .symlink : .file)
            guard kind != .file || info.st_mode & S_IFMT == S_IFREG else { throw ClientError.message("Неподдерживаемый специальный файл: \(url.lastPathComponent)") }
            return FileMetadata(kind: kind, size: kind == .file ? info.st_size : nil,
                modified: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9,
                permissions: Int(info.st_mode & 0o777), identity: info.st_ino)
        }
    }
    func contents() async throws -> [FileLocation] {
        try validate()
        let snapshot: DirectorySnapshot
        if let connection { snapshot = try await connection.contents(url, showHidden: true) }
        else { snapshot = try await LocalFileSystem().contents(at: url, showHidden: true) }
        return snapshot.entries.map { Self($0.url, connection: connection) }
    }
    func mkdir() async throws {
        try validate()
        if let connection { try await connection.mkdir(RemotePath(url.path)) }
        else { try await diskIO { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) } }
    }
    func remove(directory: Bool, expected: FileMetadata? = nil) async throws {
        try validate()
        if let connection { try await connection.remove(RemotePath(url.path), directory: directory, expected: expected) }
        else {
            try await diskIO {
                // Empty-directory-only removal. Never recursively delete a tree here.
                let result = url.withUnsafeFileSystemRepresentation { directory ? rmdir($0!) : unlink($0!) }
                guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
        }
    }
    func commit(to destination: Self, overwrite: Bool, permissions: Int?, expectedDestination: FileMetadata? = nil, cancellation: CancellationFlag = CancellationFlag()) async throws {
        try validate(); try destination.validate()
        if let connection {
            try await connection.commit(RemotePath(url.path), to: RemotePath(destination.url.path), overwrite: overwrite, permissions: permissions, expectedDestination: expectedDestination, cancellation: cancellation)
        } else {
            try await diskIO {
                if let permissions { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
                let result = url.withUnsafeFileSystemRepresentation { source in
                    destination.url.withUnsafeFileSystemRepresentation { target in
                        overwrite ? Darwin.rename(source!, target!) : renamex_np(source!, target!, UInt32(RENAME_EXCL))
                    }
                }
                guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
        }
    }
}

struct FileTransferEngine: Sendable {
    typealias ResolveConflict = @Sendable (FileConflict) async throws -> ConflictChoice
    let conflict: ResolveConflict
    let progress: @Sendable (UInt64) -> Void
    let cancellation: CancellationFlag

    // Returns false for skipped files. A skipped move never deletes its source.
    @discardableResult
    func transfer(_ source: FileLocation, to destination: FileLocation, move: Bool,
                  expectedDestination: FileMetadata? = nil, allowExpectedOverwrite: Bool = false,
                  depth: Int = 0) async throws -> Bool {
        try cancellation.check()
        guard depth < 256 else { throw ClientError.message("Слишком большая глубина каталогов.") }
        guard let original = try await source.metadata() else { throw ClientError.message("Источник больше не существует: \(source.url.path)") }
        if source.connection == nil && destination.connection == nil {
            let from = source.url.resolvingSymlinksInPath().standardizedFileURL.path
            let to = destination.url.resolvingSymlinksInPath().standardizedFileURL.path
            guard from != to, !to.hasPrefix(from + "/") else { throw ClientError.message("Нельзя скопировать объект в него самого.") }
        }
        guard original.kind != .symlink else { throw ClientError.message("Передача символических ссылок пока не поддерживается: \(source.url.lastPathComponent)") }
        let existing = try await destination.metadata()
        try cancellation.check()
        if original.kind == .directory {
            if let existing, existing.kind != .directory { throw ClientError.message("На месте каталога уже существует файл: \(destination.url.path)") }
            if existing == nil { try await destination.mkdir() }
            var complete = true
            for child in try await source.contents() {
                let copied = try await transfer(child, to: destination.child(child.url.lastPathComponent), move: move, depth: depth + 1)
                complete = complete && copied
            }
            try cancellation.check()
            if move && complete { try await source.remove(directory: true) }
            return complete
        }
        if let existing {
            guard existing.kind != .directory else { throw ClientError.message("На месте файла уже существует каталог: \(destination.url.path)") }
            if !(allowExpectedOverwrite && existing == expectedDestination) {
                let decision = try await conflict(FileConflict(name: destination.url.lastPathComponent,
                    detail: "\(destination.url.path)\nФайл уже существует. Заменить его содержимое?", allowsAll: !allowExpectedOverwrite))
                if decision == .skip { return false }
                if decision == .cancel { throw CancellationError() }
            }
        } else if allowExpectedOverwrite && expectedDestination != nil {
            let choice = try await conflict(FileConflict(name: destination.url.lastPathComponent,
                detail: "Удалённый файл был удалён после открытия. Создать его заново?", allowsAll: false))
            if choice == .skip { return false }
        }
        try cancellation.check()
        let temporary = try destination.parent.child(".cybergoose-\(UUID()).part")
        var committed = false
        do {
            let bytes: UInt64
            if let connection = destination.connection {
                guard source.connection == nil else { throw ClientError.message("Передача между двумя серверами пока не поддерживается.") }
                bytes = try await connection.transfer(remote: RemotePath(temporary.url.path), local: source.url, upload: true, cancellation: cancellation, progress: progress)
            } else if let connection = source.connection {
                bytes = try await connection.transfer(remote: RemotePath(source.url.path), local: temporary.url, upload: false, cancellation: cancellation, progress: progress)
            } else {
                bytes = try await diskIO {
                    let inputFD = open(source.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                    guard inputFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    let input = FileHandle(fileDescriptor: inputFD, closeOnDealloc: true)
                    defer { try? input.close() }
                    var info = stat()
                    guard fstat(inputFD, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw ClientError.message("Источник не является обычным файлом.") }
                    _ = fcntl(inputFD, F_SETFL, 0)
                    let outputFD = open(temporary.url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
                    guard outputFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
                    defer { try? output.close() }
                    var total: UInt64 = 0
                    while true {
                        try cancellation.check()
                        let chunk = try input.read(upToCount: 262144) ?? Data()
                        if chunk.isEmpty { break }
                        try output.write(contentsOf: chunk); total += UInt64(chunk.count); progress(total)
                    }
                    try output.synchronize()
                    return total
                }
            }
            try cancellation.check()
            guard try await source.metadata() == original else { throw ClientError.message("Источник изменился во время передачи. Источник сохранён: \(source.url.path)") }
            guard let temporaryInfo = try await temporary.metadata(), temporaryInfo.size == Int64(exactly: bytes),
                  original.size == nil || original.size == Int64(exactly: bytes) else {
                throw ClientError.message("Размер переданного файла не совпадает с источником.")
            }
            // Recheck after transfer: a destination changed while we were copying needs a new decision.
            let latest = try await destination.metadata()
            if latest != existing {
                if latest?.kind == .directory { throw ClientError.message("Назначение стало каталогом.") }
                let choice = try await conflict(FileConflict(name: destination.url.lastPathComponent,
                    detail: "Назначение изменилось во время передачи. Перезаписать новую версию?", allowsAll: false))
                if choice == .skip { try? await temporary.remove(directory: false); return false }
                if choice == .cancel { throw CancellationError() }
            }
            try cancellation.check()
            try await temporary.commit(to: destination, overwrite: latest != nil, permissions: latest?.permissions ?? original.permissions, expectedDestination: latest, cancellation: cancellation)
            committed = true
            guard let final = try await destination.metadata(), final.size == Int64(exactly: bytes) else { throw ClientError.message("Не удалось проверить назначение. Источник сохранён.") }
            if move {
                try cancellation.check()
                guard try await source.metadata() == original else { throw ClientError.message("Источник изменился после передачи и не был удалён.") }
                try await source.remove(directory: false, expected: original)
            }
            return true
        } catch {
            if !committed { try? await temporary.remove(directory: false) }
            throw error
        }
    }
}
