import Foundation

struct BookmarkStore {
    struct Document: Codable { var version = 1; var profiles: [ConnectionProfile] }
    let directory: URL
    // Keep the original storage directory so existing connections and trusted hosts remain available.
    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CyberGoose", isDirectory: true)) { self.directory = directory }
    var file: URL { directory.appendingPathComponent("connections.json") }
    func load() throws -> [ConnectionProfile] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: file))
        guard document.version == 1 else { throw ClientError.message("Неподдерживаемая версия файла подключений.") }
        return document.profiles
    }
    func save(_ profiles: [ConnectionProfile]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Document(profiles: profiles)).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
