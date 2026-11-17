import Foundation

// Run only against an explicitly supplied disposable test directory/bucket.
@main
struct RemoteServerChecks {
    static func main() async {
        do { try await check() }
        catch { print("Remote integration check failed: \(error.localizedDescription)"); exit(1) }
    }
    static func check() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let name = env["CG_TEST_PROTOCOL"], let kind = TransferProtocol(rawValue: name),
              let host = env["CG_TEST_HOST"], let user = env["CG_TEST_USER"], let root = env["CG_TEST_DIRECTORY"] else {
            throw ClientError.message("Set CG_TEST_PROTOCOL (sftp/scp/ftp/ftps/ftpsImplicit/s3), CG_TEST_HOST, CG_TEST_USER, CG_TEST_DIRECTORY. Use only a disposable test directory/bucket.")
        }
        var profile = ConnectionProfile(); profile.transferProtocol = kind; profile.host = host; profile.username = user
        profile.port = Int(env["CG_TEST_PORT"] ?? "") ?? kind.defaultPort; profile.initialPath = root
        profile.bucket = env["CG_TEST_BUCKET"] ?? ""; profile.region = env["CG_TEST_REGION"] ?? "us-east-1"
        profile.virtualHosted = env["CG_TEST_VIRTUAL_HOSTED"] == "1"
        if let key = env["CG_TEST_KEY"], kind.isSSH { profile.authentication = .privateKey; profile.privateKeyPath = key }
        profile = try profile.validated()
        let connection: any RemoteConnection
        let start: RemotePath
        if kind.isSSH {
            guard let fingerprint = env["CG_TEST_FINGERPRINT"] else { throw ClientError.message("Set CG_TEST_FINGERPRINT from an independent trusted source before SSH authentication.") }
            let ssh = try SSHConnection(useSCP: kind == .scp)
            let identity = try await ssh.handshake(profile)
            guard identity.fingerprint == fingerprint else { ssh.cancel(); throw ClientError.message("SSH host key mismatch. No credentials sent.") }
            start = try await ssh.authenticate(profile, secret: env["CG_TEST_SECRET"] ?? ""); connection = ssh
        } else if kind == .s3 {
            let credentials = try S3Credentials(secretKey: env["CG_TEST_SECRET"] ?? "", sessionToken: env["CG_TEST_SESSION_TOKEN"] ?? "").encoded()
            let s3 = try S3Connection(profile: profile, secret: credentials)
            start = try await s3.connect(); connection = s3
        } else {
            let ftp = try FTPConnection(profile: profile, secret: env["CG_TEST_SECRET"] ?? "")
            start = try await ftp.connect(); connection = ftp
        }
        defer { connection.cancel() }
        let folder = try start.child("cybergoose-check-\(UUID())")
        try await connection.mkdir(folder)
        let file = try folder.child("unicode-пробел '#%$.bin"), renamed = try folder.child("renamed.bin")
        let disk = try CurlTransport.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: disk) }
        let source = disk.appendingPathComponent("source"), received = disk.appendingPathComponent("downloaded")
        let data = Data((0..<(1024 * 1024)).map { UInt8($0 % 251) }); try data.write(to: source)
        let cancellation = CancellationFlag()
        do {
            _ = try await connection.transfer(remote: file, local: source, upload: true, cancellation: cancellation) { _ in }
            let listing = try await connection.contents(folder.url, showHidden: true)
            guard listing.entries.count == 1, listing.entries.first?.size == Int64(data.count) else { throw ClientError.message("Listing or uploaded size mismatch") }
            var rejected = false
            do { _ = try await connection.transfer(remote: file, local: source, upload: true, cancellation: cancellation) { _ in } }
            catch { rejected = true }
            guard rejected else { throw ClientError.message("An existing object was overwritten without confirmation") }
            try await connection.commit(file, to: renamed, overwrite: false, permissions: nil, expectedDestination: nil, cancellation: cancellation)
            _ = try await connection.transfer(remote: renamed, local: received, upload: false, cancellation: cancellation) { _ in }
            guard try Data(contentsOf: received) == data else { throw ClientError.message("Round-trip content mismatch") }
            try await connection.remove(renamed, directory: false, expected: nil)
            try await connection.remove(folder, directory: true, expected: nil)
        } catch {
            try? await connection.remove(file, directory: false, expected: nil)
            try? await connection.remove(renamed, directory: false, expected: nil)
            try? await connection.remove(folder, directory: true, expected: nil)
            throw error
        }
        print("Passed live \(kind.title): connect, mkdir, Unicode listing, upload, overwrite refusal, rename, byte-exact download, delete, rmdir")
    }
}
