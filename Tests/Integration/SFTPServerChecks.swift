import Foundation

@main
struct SFTPServerChecks {
    static func main() async {
        do { try await check() }
        catch { print("SFTP integration check failed: \(error.localizedDescription)"); exit(1) }
    }
    static func check() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["CG_TEST_HOST"], let username = env["CG_TEST_USER"],
              let key = env["CG_TEST_KEY"], let root = env["CG_TEST_DIRECTORY"], let fingerprint = env["CG_TEST_FINGERPRINT"] else {
            throw ClientError.message("Set CG_TEST_HOST, CG_TEST_USER, CG_TEST_KEY, CG_TEST_DIRECTORY, CG_TEST_FINGERPRINT. The directory must be a disposable test location.")
        }
        var profile = ConnectionProfile()
        profile.host = host; profile.port = Int(env["CG_TEST_PORT"] ?? "22") ?? 22
        profile.username = username; profile.authentication = .privateKey; profile.privateKeyPath = key; profile.initialPath = root
        profile = try profile.validated()
        let connection = try SSHConnection()
        defer { connection.cancel() }
        let identity = try await connection.handshake(profile)
        guard identity.fingerprint == fingerprint else { throw ClientError.message("Host fingerprint does not match CG_TEST_FINGERPRINT. No credentials sent.") }
        let start = try await connection.authenticate(profile, secret: env["CG_TEST_PASSPHRASE"] ?? "")
        let folder = try start.child("cybergoose-check-\(UUID())")
        try await connection.mkdir(folder)
        let remoteFile = try folder.child("unicode-пробел #%.bin")
        let renamed = try folder.child("renamed.bin")
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("cg-sftp-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: local) }
        let source = local.appendingPathComponent("source")
        let downloaded = local.appendingPathComponent("downloaded")
        let data = Data((0..<(1024 * 1024)).map { UInt8($0 % 251) })
        try data.write(to: source)
        do {
            try await connection.transfer(remote: remoteFile, local: source, upload: true) { _ in }
            let listing = try await connection.contents(folder.url, showHidden: true)
            guard listing.entries.count == 1, listing.entries[0].size == Int64(data.count) else { throw ClientError.message("Uploaded listing/size mismatch") }
            // An exclusive upload must fail instead of truncating the existing file.
            var rejected = false
            do { try await connection.transfer(remote: remoteFile, local: source, upload: true) { _ in } }
            catch { rejected = true }
            guard rejected else { throw ClientError.message("Existing destination was overwritten") }
            try await connection.rename(remoteFile, to: renamed)
            try await connection.transfer(remote: renamed, local: downloaded, upload: false) { _ in }
            let received = try Data(contentsOf: downloaded)
            guard received == data else { throw ClientError.message("Round-trip content mismatch") }
            try await connection.remove(renamed, directory: false)
            try await connection.remove(folder, directory: true)
        } catch {
            try? await connection.remove(remoteFile, directory: false)
            try? await connection.remove(renamed, directory: false)
            try? await connection.remove(folder, directory: true)
            throw error
        }
        print("Passed: pinned host key, key authentication, mkdir, Unicode listing, exclusive upload, rename, byte-exact download, unlink, rmdir")
    }
}
