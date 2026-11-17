import Foundation

struct FileEntry: Identifiable, Sendable {
    var id: URL { url }
    let url: URL
    let name: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let size: Int64?
    let modified: Date?
    let type: String
    var isParent = false
}

enum FileSort: String, CaseIterable {
    case name, size, modified, type
}

struct DirectorySnapshot: Sendable {
    let url: URL
    let entries: [FileEntry]
}

enum PanelSide { case local, remote }

