import Foundation

struct FileMetadata: Sendable, Equatable {
    enum Kind: Sendable { case file, directory, symlink }
    let kind: Kind
    let size: Int64?
    let modified: Double?
    let permissions: Int?
    let identity: UInt64?
    var version: String? = nil
}

enum FileNames {
    static func newFolder(existing: Set<String>) -> String {
        if !existing.contains("Новая папка") { return "Новая папка" }
        var suffix = 2
        while existing.contains("Новая папка (\(suffix))") { suffix += 1 }
        return "Новая папка (\(suffix))"
    }
}
