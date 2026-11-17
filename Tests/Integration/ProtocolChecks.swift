import Foundation
import CryptoKit

struct RecordedRequest: Sendable {
    let url: String
    let method: String
    let headers: [String]
    let commands: [String]
    let signature: String
    let tls: Bool
}
actor ScriptedFTP: RequestTransport {
    var requests: [RecordedRequest] = []
    var fallback: Bool
    init(fallback: Bool = false) { self.fallback = fallback }
    nonisolated func cancel() {}
    func request(url: String, user: String, secret: String, signature: String, tls: Bool,
                 method: String, headers: [String], commands: [String], input: URL?, output: URL,
                 cancellation: CancellationFlag, progress: @escaping @Sendable (UInt64) -> Void) async throws -> TransportResponse {
        try cancellation.check()
        requests.append(RecordedRequest(url: url, method: method, headers: headers, commands: commands, signature: signature, tls: tls))
        if fallback && method == "MLSD" { throw TransportFailure(status: 502, message: "Not implemented") }
        let text = method == "MLSD" ? "type=file;size=4;modify=20261117150000; файл #%.txt\r\ntype=dir; folder\r\n" : "-rw-r--r-- 1 user group 4 Nov 17 2026 old file.txt\r\n"
        try Data(text.utf8).write(to: output, options: .withoutOverwriting)
        return TransportResponse(status: 226, bytes: UInt64(text.utf8.count), headers: [:])
    }
}

actor MemoryS3: RequestTransport {
    struct Object: Sendable { let data: Data; let etag: String }
    var objects: [String: Object] = [:]
    var requests: [RecordedRequest] = []
    var serial = 0
    var raceDestination: String?
    var raceDeletion: String?
    nonisolated func cancel() {}
    func put(_ key: String, _ text: String) { serial += 1; objects[key] = Object(data: Data(text.utf8), etag: "\"v\(serial)\"") }
    func get(_ key: String) -> Data? { objects[key]?.data }
    func race(_ key: String) { raceDestination = key }
    func raceDelete(_ key: String) { raceDeletion = key }
    func request(url: String, user: String, secret: String, signature: String, tls: Bool,
                 method: String, headers: [String], commands: [String], input: URL?, output: URL,
                 cancellation: CancellationFlag, progress: @escaping @Sendable (UInt64) -> Void) async throws -> TransportResponse {
        try cancellation.check()
        precondition(user == "test-access" && secret == "test-secret")
        precondition(signature == "aws:amz:us-east-1:s3")
        requests.append(RecordedRequest(url: url, method: method, headers: headers, commands: commands, signature: signature, tls: tls))
        let c = URLComponents(string: url)!
        precondition(c.scheme == "https")
        let path = c.percentEncodedPath.removingPercentEncoding!
        precondition(path.hasPrefix("/test-bucket/"))
        let key = String(path.dropFirst("/test-bucket/".count))
        var status = 200, body = Data(), responseHeaders: [String: String] = [:]
        func header(_ name: String) -> String? { headers.first { $0.lowercased().hasPrefix(name.lowercased() + ": ") }.map { String($0.dropFirst(name.count + 2)) } }
        if method == "GET", c.queryItems?.contains(where: { $0.name == "list-type" }) == true {
            func query(_ name: String) -> String? { c.queryItems?.first { $0.name == name }?.value }
            let prefix = query("prefix") ?? "", delimiter = query("delimiter") != nil
            let maxKeys = Int(query("max-keys") ?? "1000")!
            var files: [String] = [], prefixes = Set<String>()
            for candidate in objects.keys.sorted() where candidate.hasPrefix(prefix) {
                let suffix = candidate.dropFirst(prefix.count)
                if delimiter, let slash = suffix.firstIndex(of: "/") {
                    prefixes.insert(prefix + suffix[...slash])
                } else { files.append(candidate) }
            }
            // Force pagination with an opaque token containing URL reserved characters.
            let token = "page+2/=&", second = query("continuation-token") == token
            let paginated = files.count > 2 && maxKeys > 2
            let page = Array((paginated ? (second ? Array(files.dropFirst(2)) : Array(files.prefix(2))) : Array(files.prefix(maxKeys))))
            let truncated = paginated && !second
            var xml = "<ListBucketResult><IsTruncated>\(truncated)</IsTruncated>"
            if truncated { xml += "<NextContinuationToken>page+2/=&amp;</NextContinuationToken>" }
            for file in page {
                xml += "<Contents><Key>\(CurlTransport.encode(file, slash: true))</Key><Size>\(objects[file]!.data.count)</Size><LastModified>2026-11-17T12:00:00.000Z</LastModified></Contents>"
            }
            for folder in prefixes { xml += "<CommonPrefixes><Prefix>\(CurlTransport.encode(folder, slash: true))</Prefix></CommonPrefixes>" }
            // Put EncodingType at the end to exercise order-independent decoding.
            xml += "<EncodingType>url</EncodingType></ListBucketResult>"; body = Data(xml.utf8)
        } else if method == "HEAD" || method == "GET" {
            if let object = objects[key] {
                if let match = header("If-Match"), match != object.etag { status = 412 }
                else {
                    responseHeaders = ["etag": object.etag, "content-length": String(object.data.count), "last-modified": "Tue, 17 Nov 2026 12:00:00 GMT"]
                    if method == "GET" { body = object.data }
                }
            } else { status = 404 }
        } else if method == "PUT" {
            if raceDestination == key { put(key, "rival change"); raceDestination = nil }
            if header("If-None-Match") == "*", objects[key] != nil { status = 412 }
            else if let match = header("If-Match"), match != objects[key]?.etag { status = 412 }
            else {
                let data = try Data(contentsOf: input!)
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                precondition(header("x-amz-content-sha256") == digest, "PUT must sign the real payload hash")
                serial += 1; objects[key] = Object(data: data, etag: "\"v\(serial)\"")
                responseHeaders["etag"] = objects[key]!.etag
            }
        } else if method == "DELETE" {
            if raceDeletion == key { put(key, "changed just before delete"); raceDeletion = nil }
            if let match = header("If-Match"), let object = objects[key], object.etag != match { status = 412 }
            else { objects[key] = nil; status = 204 }
        } else { preconditionFailure("Unexpected method") }
        try body.write(to: output, options: .withoutOverwriting)
        let bytes = input == nil ? UInt64(body.count) : UInt64((try? Data(contentsOf: input!).count) ?? 0)
        progress(bytes)
        return TransportResponse(status: status, bytes: bytes, headers: responseHeaders)
    }
}

@main
struct ProtocolChecks {
    static func requireFailure(_ message: String, _ operation: () async throws -> Void) async throws {
        do { try await operation() } catch { return }
        throw ClientError.message(message)
    }
    static func main() async {
        do { try await check(); print("Passed: legacy bookmarks, protocol validation, FTP MLSD/LIST/TLS/commands, S3 encoding/pagination/payload hash/ETag conflicts/conditional deletion/round-trip, cancellation") }
        catch { print("Protocol checks failed: \(error)"); exit(1) }
    }
    static func check() async throws {
        var old = ConnectionProfile(); old.host = "example.com"
        let data = try JSONEncoder().encode(old)
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for key in ["transferProtocol", "bucket", "region", "virtualHosted"] { json[key] = nil }
        let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: JSONSerialization.data(withJSONObject: json))
        precondition(decoded.transferProtocol == .sftp && decoded.port == 22)
        let folder = try CurlTransport.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source"); try Data("payload".utf8).write(to: source)
        let path = try RemotePath("/каталог #%")
        let listing = try FTPListing.machine(Data("type=cdir; .\r\ntype=pdir; ..\r\ntype=file;size=9;modify=20261117150000; a file #%.txt\r\ntype=OS.unix=slink; link\r\n".utf8), path: path)
        precondition(listing.count == 2 && listing[0].name == "a file #%.txt" && listing[1].isSymbolicLink)
        let ftpMock = ScriptedFTP()
        var ftpProfile = old; ftpProfile.transferProtocol = .ftps; ftpProfile.port = 21; ftpProfile.initialPath = "/"
        let ftp = try FTPConnection(profile: ftpProfile.validated(), secret: "secret", transport: ftpMock)
        let ftpEntries = try await ftp.contents(path.url, showHidden: true)
        precondition(ftpEntries.entries.count == 2)
        try await ftp.mkdir(path.child("new"))
        let ftpCalls = await ftpMock.requests
        precondition(ftpCalls.allSatisfy { $0.tls && $0.url.hasPrefix("ftp://") })
        precondition(ftpCalls[0].url.contains("%23%25") && ftpCalls[1].commands == ["MKD /каталог #%/new"])
        try await requireFailure("FTP command injection accepted") { try await ftp.mkdir(RemotePath("/bad\r\nDELE /x")) }
        let fallback = try FTPConnection(profile: ftpProfile, secret: "secret", transport: ScriptedFTP(fallback: true))
        let fallbackEntries = try await fallback.contents(RemotePath("/").url, showHidden: true)
        precondition(fallbackEntries.entries.first?.name == "old file.txt")
        var profile = ConnectionProfile(); profile.transferProtocol = .s3; profile.host = "s3.example.com"; profile.port = 443
        profile.username = "test-access"; profile.bucket = "test-bucket"; profile.initialPath = "/"
        profile = try profile.validated()
        let mock = MemoryS3()
        await mock.put("file #%.txt", "one"); await mock.put("two", "two"); await mock.put("три", "three"); await mock.put("folder/child", "child")
        let secret = try S3Credentials(secretKey: "test-secret", sessionToken: "temporary-token").encoded()
        let s3 = try S3Connection(profile: profile, secret: secret, transport: mock)
        _ = try await s3.connect()
        let entries = try await s3.contents(RemotePath("/").url, showHidden: true).entries
        precondition(Set(entries.map(\.name)) == Set(["file #%.txt", "two", "три", "folder"]))
        let implicit = try await s3.metadata(RemotePath("/folder")); precondition(implicit?.kind == .directory)
        let calls = await mock.requests
        precondition(calls.contains { $0.url.contains("page%2B2%2F%3D%26") })
        precondition(calls.allSatisfy { $0.headers.contains("x-amz-security-token: temporary-token") })
        let cancellation = CancellationFlag()
        _ = try await s3.transfer(remote: RemotePath("/new #%.bin"), local: source, upload: true, cancellation: cancellation) { _ in }
        let downloaded = folder.appendingPathComponent("download")
        _ = try await s3.transfer(remote: RemotePath("/new #%.bin"), local: downloaded, upload: false, cancellation: cancellation) { _ in }
        let received = try Data(contentsOf: downloaded); precondition(received == Data("payload".utf8))
        try await requireFailure("S3 exclusive upload overwrote an object") {
            _ = try await s3.transfer(remote: RemotePath("/new #%.bin"), local: source, upload: true, cancellation: cancellation) { _ in }
        }
        try await s3.mkdir(RemotePath("/empty")); try await s3.remove(RemotePath("/empty"), directory: true)
        try await requireFailure("S3 removed a nonempty folder") { try await s3.remove(RemotePath("/folder"), directory: true) }
        try await s3.commit(RemotePath("/new #%.bin"), to: RemotePath("/renamed"), overwrite: false, permissions: nil)
        let moved = await mock.get("renamed"), removed = await mock.get("new #%.bin")
        precondition(moved == Data("payload".utf8) && removed == nil)
        let expected = try await s3.metadata(RemotePath("/renamed"))!
        await mock.put("staging", "replacement"); await mock.race("renamed")
        try await requireFailure("S3 overwrote a concurrent change") {
            try await s3.commit(RemotePath("/staging"), to: RemotePath("/renamed"), overwrite: true, permissions: nil, expectedDestination: expected)
        }
        let rival = await mock.get("renamed"), retained = await mock.get("staging")
        precondition(rival == Data("rival change".utf8) && retained == Data("replacement".utf8))
        try await requireFailure("S3 deleted a changed source") { try await s3.remove(RemotePath("/renamed"), directory: false, expected: expected) }
        await mock.put("delete-race", "original")
        let deletionVersion = try await s3.metadata(RemotePath("/delete-race"))!
        await mock.raceDelete("delete-race")
        try await requireFailure("S3 ignored the conditional DELETE") { try await s3.remove(RemotePath("/delete-race"), directory: false, expected: deletionVersion) }
        let retainedAfterDelete = await mock.get("delete-race")
        precondition(retainedAfterDelete == Data("changed just before delete".utf8))
        await mock.put("overwrite-source", "approved replacement")
        let overwriteVersion = try await s3.metadata(RemotePath("/renamed"))!
        try await s3.commit(RemotePath("/overwrite-source"), to: RemotePath("/renamed"), overwrite: true, permissions: nil, expectedDestination: overwriteVersion)
        let replaced = await mock.get("renamed"); precondition(replaced == Data("approved replacement".utf8))
        let implicitProfile = { var p = ftpProfile; p.transferProtocol = .ftpsImplicit; p.port = 990; return p }()
        let implicitTransport = ScriptedFTP()
        let implicitFTP = try FTPConnection(profile: implicitProfile, secret: "secret", transport: implicitTransport)
        _ = try await implicitFTP.connect()
        let implicitCalls = await implicitTransport.requests
        precondition(implicitCalls[0].tls && implicitCalls[0].url.hasPrefix("ftps://"))
        var hosted = profile; hosted.virtualHosted = true
        let hostedS3 = try S3Connection(profile: hosted, secret: secret, transport: mock)
        precondition(hostedS3.address(key: "a #%.txt").contains("test-bucket.s3.example.com"))
        precondition(hostedS3.address(key: "a #%.txt").contains("/a%20%23%25.txt"))
        cancellation.cancel()
        try await requireFailure("Cancelled S3 transfer ran") {
            _ = try await s3.transfer(remote: RemotePath("/cancelled"), local: source, upload: true, cancellation: cancellation) { _ in }
        }
        try await requireFailure("S3 dot-segment key accepted") { _ = try S3Connection.key(RemotePath("/a/../b")) }
        try await requireFailure("Malformed XML accepted") { _ = try S3XML.parse(Data("<ListBucketResult><Contents><Key>a</Key></Contents></ListBucketResult>".utf8)) }
        var changed = profile; changed.bucket = "different"; precondition(changed.resourceIdentity != profile.resourceIdentity)
        let bookmark = try JSONEncoder().encode(profile)
        precondition(!String(decoding: bookmark, as: UTF8.self).contains("test-secret"))
    }
}
