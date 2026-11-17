import Foundation
import CryptoKit
import Darwin

struct S3Credentials: Codable, Sendable {
    let secretKey: String
    let sessionToken: String
    static func decode(_ value: String) -> Self {
        (try? JSONDecoder().decode(Self.self, from: Data(value.utf8))) ?? Self(secretKey: value, sessionToken: "")
    }
    func encoded() throws -> String { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }
}

final class S3Connection: RemoteConnection, Sendable {
    let profile: ConnectionProfile
    private let credentials: S3Credentials
    private let transport: any RequestTransport
    static let maximumUpload: Int64 = 5 * 1024 * 1024 * 1024
    init(profile: ConnectionProfile, secret: String, transport: (any RequestTransport)? = nil) throws {
        self.profile = profile; credentials = S3Credentials.decode(secret); self.transport = try transport ?? CurlTransport()
        guard !credentials.secretKey.isEmpty,
              credentials.sessionToken.rangeOfCharacter(from: .controlCharacters) == nil else { throw ClientError.message("Укажите S3 Secret Access Key. Session Token не должен содержать управляющих символов.") }
    }
    func cancel() { transport.cancel() }
    func connect() async throws -> RemotePath {
        let path = try RemotePath(profile.initialPath)
        // Listing also verifies credentials, bucket, region and ListBucket permission.
        _ = try await contents(path.url, showHidden: true)
        return path
    }
    static func key(_ path: RemotePath) throws -> String {
        let key = String(path.value.dropFirst())
        // Foundation URL navigation normalizes dot segments. Do not expose keys
        // whose names cannot round-trip through a filesystem-style UI.
        guard !key.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }),
              !key.contains("//"), key.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ClientError.message("S3: ключи с . / .., пустыми сегментами или управляющими символами не поддерживаются.")
        }
        return key
    }
    func address(key: String, query: [(String, String)] = []) -> String {
        var c = URLComponents(); c.scheme = "https"
        c.host = profile.virtualHosted ? profile.bucket + "." + profile.host : profile.host; c.port = profile.port
        let path = (profile.virtualHosted ? "/" : "/" + profile.bucket + "/") + key
        c.percentEncodedPath = CurlTransport.encode(path, slash: true)
        if !query.isEmpty {
            let encoded = query.map { (CurlTransport.encode($0.0), CurlTransport.encode($0.1)) }
            let sorted = encoded.sorted { a, b in a.0 == b.0 ? a.1 < b.1 : a.0 < b.0 }
            c.percentEncodedQuery = sorted.map { pair in pair.0 + "=" + pair.1 }.joined(separator: "&")
        }
        return c.url!.absoluteString
    }
    private func request(key: String, query: [(String, String)] = [], method: String = "GET", headers: [String] = [],
                         input: URL? = nil, output: URL, accepted: Set<Int> = [],
                         cancellation: CancellationFlag = CancellationFlag(), progress: @escaping @Sendable (UInt64) -> Void = { _ in }) async throws -> TransportResponse {
        var headers = headers
        if !credentials.sessionToken.isEmpty { headers.append("x-amz-security-token: " + credentials.sessionToken) }
        // libcurl signs the request; CryptoKit only supplies a streaming payload
        // checksum. File bodies never have to fit into memory.
        let digest = try await Self.digest(input, cancellation: cancellation)
        headers.append("x-amz-content-sha256: " + digest)
        let response = try await transport.request(url: address(key: key, query: query), user: profile.username, secret: credentials.secretKey,
            signature: "aws:amz:\(profile.region):s3", tls: false, method: method, headers: headers, commands: [], input: input, output: output,
            cancellation: cancellation, progress: progress)
        guard (200..<300).contains(response.status) || accepted.contains(response.status) else {
            var detail = "S3: HTTP \(response.status)."
            if response.status == 409 || response.status == 412 { detail += " Объект изменился; обновите панель и повторите операцию." }
            if let region = response.headers["x-amz-bucket-region"] { detail += " Регион bucket: \(region)." }
            // Return only the service error code, never the body (which can echo credentials).
            if method != "HEAD", let data = try? Data(contentsOf: output), let xml = try? S3XML.parse(data), let code = xml.errorCode {
                detail += " " + code
            }
            throw TransportFailure(status: response.status, message: detail)
        }
        return response
    }
    private static func digest(_ file: URL?, cancellation: CancellationFlag) async throws -> String {
        try await Task.detached(priority: .utility) {
            var hash = SHA256()
            if let file {
                let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                guard fd >= 0 else { throw ClientError.message("Не удалось открыть файл для контрольной суммы.") }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
                var info = stat()
                guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw ClientError.message("S3: источник должен быть обычным файлом.") }
                _ = fcntl(fd, F_SETFL, 0)
                guard info.st_size <= maximumUpload else { throw ClientError.message("S3: файлы больше 5 GiB требуют multipart upload; эта версия его пока не поддерживает.") }
                while true {
                    try cancellation.check()
                    let data = try handle.read(upToCount: 262144) ?? Data()
                    if data.isEmpty { break }
                    hash.update(data: data)
                }
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
    private func folderPrefix(_ key: String) -> String { key.isEmpty || key.hasSuffix("/") ? key : key + "/" }
    private func page(prefix: String, token: String? = nil, delimiter: Bool = true, maximum: Int = 1000) async throws -> S3XML {
        let folder = try CurlTransport.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("list.xml")
        var query = [("list-type", "2"), ("encoding-type", "url"), ("prefix", prefix), ("max-keys", String(maximum))]
        if delimiter { query.append(("delimiter", "/")) }
        if let token { query.append(("continuation-token", token)) }
        _ = try await request(key: "", query: query, output: output)
        let listing = try S3XML.parse(Data(contentsOf: output))
        guard listing.isListing else { throw ClientError.message("S3: вместо списка объектов сервер вернул ошибку.") }
        return listing
    }
    func contents(_ url: URL, showHidden: Bool) async throws -> DirectorySnapshot {
        let path = try RemotePath(url.path), key = try Self.key(path)
        let prefix = folderPrefix(key)
        var token: String?, seen = Set<String>(), entries: [String: FileEntry] = [:]
        repeat {
            let result = try await page(prefix: prefix, token: token)
            for object in result.objects {
                if object.key == prefix { continue } // Folder marker, not its own child.
                guard object.key.hasPrefix(prefix) else { throw ClientError.message("S3: сервер вернул ключ вне каталога.") }
                let name = String(object.key.dropFirst(prefix.count))
                // Folder markers may appear as Contents on some compatible services.
                let directory = name.hasSuffix("/")
                let childName = directory ? String(name.dropLast()) : name
                _ = try Self.key(RemotePath("/" + object.key))
                let child = try path.child(childName)
                if let previous = entries[childName], previous.isDirectory != directory { throw ClientError.message("S3: объект и каталог имеют одинаковое имя «\(childName)».") }
                entries[childName] = FileEntry(url: child.url, name: childName, isDirectory: directory, isSymbolicLink: false,
                    size: directory ? nil : object.size, modified: object.modified, type: directory ? "Папка" : "Объект S3")
            }
            for common in result.prefixes {
                guard common.hasPrefix(prefix), common.hasSuffix("/") else { throw ClientError.message("S3: некорректный префикс каталога.") }
                let name = String(common.dropFirst(prefix.count).dropLast())
                _ = try Self.key(RemotePath("/" + common))
                let child = try path.child(name)
                if entries[name]?.isDirectory == false { throw ClientError.message("S3: объект и каталог имеют одинаковое имя «\(name)»; эта структура не поддерживается.") }
                entries[name] = FileEntry(url: child.url, name: name, isDirectory: true, isSymbolicLink: false, size: nil, modified: nil, type: "Папка")
            }
            token = result.truncated ? result.nextToken : nil
            if result.truncated && (token == nil || !seen.insert(token!).inserted) { throw ClientError.message("S3: сервер не вернул новый continuation token.") }
        } while token != nil
        return DirectorySnapshot(url: path.url, entries: entries.values.filter { showHidden || !$0.name.hasPrefix(".") })
    }
    private func head(_ key: String) async throws -> FileMetadata? {
        let folder = try CurlTransport.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: folder) }
        let response = try await request(key: key, method: "HEAD", output: folder.appendingPathComponent("head"), accepted: [404])
        if response.status == 404 { return nil }
        guard let size = response.headers["content-length"].flatMap(Int64.init), let etag = response.headers["etag"] else {
            throw ClientError.message("S3: сервер не вернул размер или ETag объекта.")
        }
        return FileMetadata(kind: .file, size: size, modified: Self.httpDate(response.headers["last-modified"]), permissions: nil, identity: nil, version: etag)
    }
    func metadata(_ path: RemotePath) async throws -> FileMetadata? {
        let key = try Self.key(path)
        if key.isEmpty { return FileMetadata(kind: .directory, size: nil, modified: nil, permissions: nil, identity: nil) }
        if let file = try await head(key) { return file }
        let result = try await page(prefix: folderPrefix(key), delimiter: false, maximum: 1)
        if !result.objects.isEmpty { return FileMetadata(kind: .directory, size: nil, modified: nil, permissions: nil, identity: nil) }
        return nil
    }
    private static func httpDate(_ value: String?) -> Double? {
        guard let value else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: value)?.timeIntervalSince1970
    }
    func mkdir(_ path: RemotePath) async throws {
        let key = try Self.key(path)
        guard !key.isEmpty, try await metadata(path) == nil else { throw ClientError.message("S3: имя уже занято.") }
        let folder = try CurlTransport.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: folder) }
        let empty = folder.appendingPathComponent("empty"); try Data().write(to: empty)
        _ = try await request(key: folderPrefix(key), method: "PUT", headers: ["If-None-Match: *"], input: empty, output: folder.appendingPathComponent("reply"))
    }
    private func deleteObject(_ key: String, version: String?) async throws {
        let folder = try CurlTransport.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: folder) }
        _ = try await request(key: key, method: "DELETE", headers: version.map { ["If-Match: " + $0] } ?? [], output: folder.appendingPathComponent("reply"))
    }
    func remove(_ path: RemotePath, directory: Bool, expected: FileMetadata? = nil) async throws {
        let key = try Self.key(path)
        guard !key.isEmpty else { throw ClientError.message("Удаление bucket не поддерживается.") }
        if directory {
            let prefix = folderPrefix(key), listing = try await page(prefix: folderPrefix(key), delimiter: false, maximum: 2)
            guard listing.objects.allSatisfy({ $0.key == prefix }), !listing.truncated else { throw ClientError.message("S3: каталог не пуст.") }
            if let marker = try await head(prefix) { try await deleteObject(prefix, version: marker.version) }
        } else {
            guard let info = try await head(key) else { throw ClientError.message("S3: объект больше не существует.") }
            if let expected, info != expected { throw ClientError.message("S3: источник изменился и не был удалён.") }
            try await deleteObject(key, version: info.version)
        }
    }
    func transfer(remote: RemotePath, local: URL, upload: Bool, cancellation: CancellationFlag,
                  progress: @escaping @Sendable (UInt64) -> Void) async throws -> UInt64 {
        let key = try Self.key(remote)
        guard !key.isEmpty else { throw ClientError.message("Нельзя передавать bucket как файл.") }
        let folder = try CurlTransport.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: folder) }
        let response = try await request(key: key, method: upload ? "PUT" : "GET", headers: upload ? ["If-None-Match: *"] : [],
            input: upload ? local : nil, output: upload ? folder.appendingPathComponent("reply") : local, cancellation: cancellation, progress: progress)
        progress(response.bytes); return response.bytes
    }
    func commit(_ source: RemotePath, to destination: RemotePath, overwrite: Bool, permissions: Int?, expectedDestination: FileMetadata? = nil, cancellation: CancellationFlag = CancellationFlag()) async throws {
        try cancellation.check()
        guard let original = try await metadata(source) else { throw ClientError.message("S3: источник исчез.") }
        if original.kind == .directory {
            throw ClientError.message("S3: переименование каталогов-префиксов пока не поддерживается. Файлы можно переименовывать; каталоги можно передавать рекурсивно.")
        }
        let from = try Self.key(source), to = try Self.key(destination)
        guard !to.isEmpty, from != to else { throw ClientError.message("S3: некорректное назначение.") }
        let existing = try await metadata(destination)
        if overwrite, existing != expectedDestination { throw ClientError.message("S3: назначение изменилось после подтверждения замены.") }
        guard existing?.kind != .directory else { throw ClientError.message("S3: назначение является каталогом.") }
        if !overwrite, existing != nil { throw ClientError.message("S3: объект назначения уже существует.") }
        guard original.size.map({ $0 <= Self.maximumUpload }) == true else { throw ClientError.message("S3: переименование объектов больше 5 GiB требует multipart upload.") }
        // A conditional PUT protects the destination even if it changes during
        // the transfer. CopyObject cannot provide this destination precondition.
        // Stream through a private disk file instead of buffering in RAM.
        let folder = try CurlTransport.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: folder) }
        let data = folder.appendingPathComponent("object")
        let downloaded = try await request(key: from, headers: original.version.map { ["If-Match: " + $0] } ?? [], output: data, cancellation: cancellation)
        let preserved = downloaded.headers.filter { key, _ in
            key.hasPrefix("x-amz-meta-") || ["content-type", "cache-control", "content-disposition", "content-encoding", "content-language", "expires"].contains(key)
        }.map { $0.key + ": " + $0.value }
        let condition = existing?.version.map { "If-Match: " + $0 } ?? "If-None-Match: *"
        _ = try await request(key: to, method: "PUT", headers: [condition] + preserved, input: data, output: folder.appendingPathComponent("reply"), cancellation: cancellation)
        guard let final = try await head(to), final.size == original.size else { throw ClientError.message("S3: назначение не прошло проверку; источник сохранён.") }
        // ETag-guarded deletion leaves the source intact if it changed.
        try cancellation.check()
        try await deleteObject(from, version: original.version)
    }
}

// Only the small XML listing is loaded into memory, never file payloads.
final class S3XML: NSObject, XMLParserDelegate {
    struct Object { let key: String; let size: Int64; let modified: Date? }
    var objects: [Object] = []
    var prefixes: [String] = []
    var truncated = false
    var nextToken: String?
    var errorCode: String?
    private var stack: [String] = []
    private var text = ""
    private var object: [String: String] = [:]
    private var urlEncoded = false
    private var invalid = false
    private var root: String?
    var isListing: Bool { root == "ListBucketResult" }
    static func parse(_ data: Data) throws -> S3XML {
        let result = S3XML(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = result
        guard parser.parse(), !result.invalid, ["ListBucketResult", "Error"].contains(result.root ?? "") else { throw ClientError.message("S3: некорректный XML-ответ.") }
        if result.urlEncoded {
            result.objects = result.objects.map { Object(key: result.decode($0.key), size: $0.size, modified: $0.modified) }
            result.prefixes = result.prefixes.map { result.decode($0) }
        }
        guard !result.invalid else { throw ClientError.message("S3: некорректная кодировка ключа.") }
        return result
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if stack.isEmpty { root = elementName }
        stack.append(elementName); text = ""
        if elementName == "Contents" { object = [:] }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let parent = stack.dropLast().last
        if elementName == "EncodingType" { urlEncoded = text == "url" }
        if parent == "Contents" { object[elementName] = text }
        if elementName == "Contents" {
            guard let key = object["Key"], let size = object["Size"].flatMap(Int64.init), size >= 0 else { invalid = true; stack.removeLast(); return }
            let iso = ISO8601DateFormatter()
            let modified = object["LastModified"].flatMap { iso.date(from: $0) ?? { iso.formatOptions.insert(.withFractionalSeconds); return iso.date(from: $0) }($0) }
            objects.append(Object(key: key, size: size, modified: modified))
        }
        if elementName == "Prefix", parent == "CommonPrefixes" { prefixes.append(text) }
        if elementName == "IsTruncated" { truncated = text.trimmingCharacters(in: .whitespacesAndNewlines) == "true" }
        if elementName == "NextContinuationToken" { nextToken = text.isEmpty ? nil : text }
        if elementName == "Code", parent == "Error" { errorCode = text }
        stack.removeLast(); text = ""
    }
    private func decode(_ value: String) -> String {
        if !urlEncoded { return value }
        guard let decoded = value.removingPercentEncoding else { invalid = true; return value }
        return decoded
    }
}
