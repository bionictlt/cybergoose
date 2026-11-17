import Foundation

final class FTPConnection: RemoteConnection, Sendable {
    let profile: ConnectionProfile
    private let secret: String
    private let transport: any RequestTransport
    init(profile: ConnectionProfile, secret: String, transport: (any RequestTransport)? = nil) throws {
        self.profile = profile; self.secret = secret; self.transport = try transport ?? CurlTransport()
    }
    func cancel() { transport.cancel() }
    func connect() async throws -> RemotePath {
        let path = try RemotePath(profile.initialPath)
        _ = try await contents(path.url, showHidden: true)
        return path
    }
    private func address(_ path: RemotePath, directory: Bool = false) -> String {
        var c = URLComponents(); c.scheme = profile.transferProtocol == .ftpsImplicit ? "ftps" : "ftp"
        c.host = profile.host; c.port = profile.port
        // An extra slash requests an absolute FTP path, independent of login CWD.
        c.percentEncodedPath = "/" + CurlTransport.encode(path.value, slash: true) + (directory && !path.value.hasSuffix("/") ? "/" : "")
        return c.url!.absoluteString
    }
    private func request(_ path: RemotePath, directory: Bool = false, method: String = "GET", commands: [String] = [],
                         input: URL? = nil, output: URL, cancellation: CancellationFlag = CancellationFlag(),
                         progress: @escaping @Sendable (UInt64) -> Void = { _ in }) async throws -> TransportResponse {
        let response = try await transport.request(url: address(path, directory: directory), user: profile.username, secret: secret,
            signature: "", tls: profile.transferProtocol != .ftp, method: method, headers: [], commands: commands, input: input, output: output,
            cancellation: cancellation, progress: progress)
        guard response.status < 400 else { throw TransportFailure(status: response.status, message: "FTP: ответ сервера \(response.status).") }
        return response
    }
    func contents(_ url: URL, showHidden: Bool) async throws -> DirectorySnapshot {
        let path = try RemotePath(url.path)
        let folder = try CurlTransport.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("listing")
        let entries: [FileEntry]
        do {
            _ = try await request(path, directory: true, method: "MLSD", output: output)
            entries = try FTPListing.machine(Data(contentsOf: output), path: path)
        } catch let error as TransportFailure where [500, 501, 502, 504].contains(error.status) {
            try? FileManager.default.removeItem(at: output)
            _ = try await request(path, directory: true, output: output)
            entries = try FTPListing.unix(Data(contentsOf: output), path: path)
        }
        return DirectorySnapshot(url: path.url, entries: entries.filter { showHidden || !$0.name.hasPrefix(".") })
    }
    func metadata(_ path: RemotePath) async throws -> FileMetadata? {
        if path.value == "/" { return FileMetadata(kind: .directory, size: nil, modified: nil, permissions: nil, identity: nil) }
        let parent = try RemotePath(path.url.deletingLastPathComponent().path)
        let entries = try await contents(parent.url, showHidden: true).entries
        guard let entry = entries.first(where: { $0.name == path.url.lastPathComponent }) else { return nil }
        return FileMetadata(kind: entry.isSymbolicLink ? .symlink : (entry.isDirectory ? .directory : .file), size: entry.size,
            modified: entry.modified?.timeIntervalSince1970, permissions: nil, identity: nil)
    }
    private func command(_ commands: [String], cancellation: CancellationFlag = CancellationFlag()) async throws {
        let folder = try CurlTransport.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: folder) }
        _ = try await request(RemotePath("/"), method: "COMMAND", commands: commands, output: folder.appendingPathComponent("reply"), cancellation: cancellation)
    }
    private func safe(_ path: RemotePath) throws -> String {
        guard path.value.rangeOfCharacter(from: .controlCharacters) == nil else { throw ClientError.message("FTP не поддерживает управляющие символы в пути.") }
        return path.value
    }
    func mkdir(_ path: RemotePath) async throws { try await command(["MKD " + safe(path)]) }
    func remove(_ path: RemotePath, directory: Bool, expected: FileMetadata? = nil) async throws {
        if let expected, try await metadata(path) != expected { throw ClientError.message("FTP: источник изменился и не был удалён.") }
        try await command([(directory ? "RMD " : "DELE ") + safe(path)])
    }
    func commit(_ source: RemotePath, to destination: RemotePath, overwrite: Bool, permissions: Int?, expectedDestination: FileMetadata? = nil, cancellation: CancellationFlag = CancellationFlag()) async throws {
        try cancellation.check()
        let existing = try await metadata(destination)
        if overwrite, existing != expectedDestination { throw ClientError.message("FTP: назначение изменилось после подтверждения замены.") }
        if !overwrite, existing != nil { throw ClientError.message("FTP: имя назначения уже занято.") }
        // Never delete the destination before RNTO. FTP servers decide whether
        // replacement is supported; FTP has no conditional atomic rename.
        try await command(["RNFR " + safe(source), "RNTO " + safe(destination)], cancellation: cancellation)
    }
    func transfer(remote: RemotePath, local: URL, upload: Bool, cancellation: CancellationFlag,
                  progress: @escaping @Sendable (UInt64) -> Void) async throws -> UInt64 {
        _ = try safe(remote)
        if upload, try await metadata(remote) != nil { throw ClientError.message("FTP: файл назначения уже существует.") }
        let folder = try CurlTransport.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: folder) }
        let response = try await request(remote, method: upload ? "PUT" : "GET", input: upload ? local : nil,
            output: upload ? folder.appendingPathComponent("reply") : local, cancellation: cancellation, progress: progress)
        progress(response.bytes)
        return response.bytes
    }
}

// Prefer RFC 3659 MLSD. Older servers may fall back to a conservative Unix LIST
// parser; unknown formats fail rather than treating directories as regular files.
enum FTPListing {
    static func machine(_ data: Data, path: RemotePath) throws -> [FileEntry] {
        guard let text = String(data: data, encoding: .utf8) else { throw ClientError.message("FTP: список файлов должен быть в UTF-8.") }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMddHHmmss"
        return try text.components(separatedBy: "\n").compactMap { raw in
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.isEmpty { return nil }
            guard let space = line.firstIndex(of: " ") else { throw ClientError.message("FTP: некорректный ответ MLSD.") }
            let name = String(line[line.index(after: space)...])
            var facts: [String: String] = [:]
            for fact in line[..<space].split(separator: ";") {
                let pair = fact.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if pair.count == 2 { facts[pair[0].lowercased()] = String(pair[1]) }
            }
            let type = facts["type"]?.lowercased() ?? ""
            if type == "cdir" || type == "pdir" || name == "." || name == ".." { return nil }
            let symlink = type.contains("slink") || type.contains("symlink")
            guard type == "file" || type == "dir" || symlink else { throw ClientError.message("FTP: неподдерживаемый тип MLSD: \(type).") }
            let directory = type == "dir"
            return FileEntry(url: try path.child(name).url, name: name, isDirectory: directory, isSymbolicLink: symlink,
                size: directory ? nil : facts["size"].flatMap(Int64.init),
                modified: facts["modify"].flatMap { formatter.date(from: String($0.prefix(14))) },
                type: directory ? "Папка" : (symlink ? "Ссылка" : "Файл"))
        }
    }
    static func unix(_ data: Data, path: RemotePath) throws -> [FileEntry] {
        guard let text = String(data: data, encoding: .utf8) else { throw ClientError.message("FTP: список файлов должен быть в UTF-8.") }
        let regex = try NSRegularExpression(pattern: #"^([dl-])[rwxstST-]{9}[+@.]?\s+\d+\s+\S+\s+\S+\s+(\d+)\s+([A-Za-z]{3})\s+(\d{1,2})\s+(\d{2}:\d{2}|\d{4})\s(.*)$"#)
        return try text.components(separatedBy: "\n").compactMap { raw in
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.isEmpty || line.hasPrefix("total ") { return nil }
            guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { throw ClientError.message("FTP: сервер не поддерживает MLSD и вернул неизвестный формат LIST.") }
            func field(_ index: Int) -> String { String(line[Range(match.range(at: index), in: line)!]) }
            let kind = field(1), symlink = kind == "l", directory = kind == "d"
            let name = symlink ? String(field(6).components(separatedBy: " -> ")[0]) : field(6)
            if name == "." || name == ".." { return nil }
            return FileEntry(url: try path.child(name).url, name: name, isDirectory: directory, isSymbolicLink: symlink,
                size: directory ? nil : Int64(field(2)), modified: nil, type: directory ? "Папка" : (symlink ? "Ссылка" : "Файл"))
        }
    }
}
