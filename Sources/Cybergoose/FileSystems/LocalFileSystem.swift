import Foundation
import UniformTypeIdentifiers

protocol FileSystem: Sendable {
    func contents(at url: URL, showHidden: Bool) async throws -> DirectorySnapshot
}

struct LocalFileSystem: FileSystem {
    func contents(at url: URL, showHidden: Bool) async throws -> DirectorySnapshot {
        // FileManager's synchronous calls run on a utility queue, never MainActor.
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
                    let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys), options: showHidden ? [] : [.skipsHiddenFiles])
                    let entries = try urls.map { item in
                        let values = try item.resourceValues(forKeys: keys)
                        let directory = values.isDirectory == true
                        return FileEntry(url: item, name: item.lastPathComponent,
                            isDirectory: directory, isSymbolicLink: values.isSymbolicLink == true,
                            size: directory ? nil : values.fileSize.map(Int64.init),
                            modified: values.contentModificationDate,
                            type: directory ? "Папка" : (item.pathExtension.isEmpty ? "Файл" : item.pathExtension.uppercased()))
                    }
                    continuation.resume(returning: DirectorySnapshot(url: url, entries: entries))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
