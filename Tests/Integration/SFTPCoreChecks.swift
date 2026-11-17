import Foundation

@main
struct SFTPCoreChecks {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cybergoose-check-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BookmarkStore(directory: root)
        var profile = ConnectionProfile()
        profile.name = "Тест"; profile.host = "EXAMPLE.COM"; profile.username = "tester"
        profile = try profile.validated()
        precondition(profile.host == "example.com")
        try store.save([profile])
        let loaded = try store.load()
        precondition(loaded.count == 1 && loaded[0].id == profile.id)
        let json = try String(contentsOf: store.file, encoding: .utf8)
        precondition(!json.contains("secret") && !json.contains("passphrase"))
        let mode = try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as! NSNumber
        precondition(mode.intValue & 0o777 == 0o600)
        let trust = KnownHostsStore(directory: root)
        let first = HostIdentity(key: Data("first host key".utf8), algorithm: "Ed25519")
        let changed = HostIdentity(key: Data("changed host key".utf8), algorithm: "Ed25519")
        let unknown = try trust.check(first, for: profile)
        precondition(!unknown)
        try trust.trust(first, for: profile)
        let known = try trust.check(first, for: profile)
        precondition(known)
        var rejected = false
        do { _ = try trust.check(changed, for: profile) } catch { rejected = true }
        precondition(rejected, "Changed host key must be rejected")
        rejected = false
        do { try trust.trust(changed, for: profile) } catch { rejected = true }
        precondition(rejected, "Changed host key must not be silently replaced")
        var otherPort = profile; otherPort.port = 2222
        let differentEndpoint = try trust.check(first, for: otherPort)
        precondition(!differentEndpoint)
        let path = try RemotePath("/каталог с пробелом").child("#100%?.txt")
        precondition(path.url.path == "/каталог с пробелом/#100%?.txt")
        let uncollapsed = try RemotePath("/link/../folder")
        precondition(uncollapsed.value == "/link/../folder")
        for name in ["", ".", "..", "a/b", "a\0b"] {
            rejected = false
            do { _ = try RemotePath("/").child(name) } catch { rejected = true }
            precondition(rejected)
        }
        // Cancellation is safe before creation of the socket/session, too.
        let connection = try SSHConnection()
        connection.cancel()
        profile.host = "127.0.0.1"
        rejected = false
        do { _ = try await connection.handshake(profile) } catch { rejected = true }
        precondition(rejected)
        // Corrupt trust storage must fail closed rather than treat all hosts as unknown.
        try Data("broken".utf8).write(to: trust.file)
        rejected = false
        do { _ = try trust.check(first, for: profile) } catch { rejected = true }
        precondition(rejected)
        print("Passed: bookmark round-trip/permissions, unknown/known/changed host keys, port isolation, remote path escaping, cancellation, corrupt trust store")
    }
}
