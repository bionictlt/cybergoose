import Foundation
import CryptoKit

struct HostIdentity: Codable, Sendable, Equatable {
    let key: Data
    let algorithm: String
    var fingerprint: String { "SHA256:" + Data(SHA256.hash(data: key)).base64EncodedString().replacingOccurrences(of: "=", with: "") }
}

struct HostTrustRequest: Identifiable {
    let id = UUID()
    let profile: ConnectionProfile
    let identity: HostIdentity
}

struct KnownHostsStore {
    let file: URL
    init(directory: URL = BookmarkStore().directory) { file = directory.appendingPathComponent("known-hosts.json") }
    func check(_ identity: HostIdentity, for profile: ConnectionProfile) throws -> Bool {
        let hosts = try load()
        guard let saved = hosts[profile.endpoint] else { return false }
        guard saved.key == identity.key else {
            throw ClientError.message("Ключ сервера \(profile.endpoint) изменился. Подключение заблокировано.\nСохранённый: \(saved.fingerprint)\nПолученный: \(identity.fingerprint)\nСверьте ключ с администратором сервера. Доверенные ключи находятся в \(file.path).")
        }
        return true
    }
    func trust(_ identity: HostIdentity, for profile: ConnectionProfile) throws {
        var hosts = try load()
        if let old = hosts[profile.endpoint], old.key != identity.key { throw ClientError.message("Нельзя автоматически заменить изменившийся ключ сервера.") }
        hosts[profile.endpoint] = identity
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(hosts).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private func load() throws -> [String: HostIdentity] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        return try JSONDecoder().decode([String: HostIdentity].self, from: Data(contentsOf: file))
    }
}
