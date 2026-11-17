import Foundation
import Observation

@MainActor @Observable
final class PanelModel {
    var path: URL
    var pathText: String
    var entries: [FileEntry] = []
    var selection: Set<URL> = []
    var loading = false
    var sort: FileSort = .name
    var ascending = true
    var revision = UUID()
    var focusRequest: UUID?
    private var selectFirstOnLoad = false
    var errorHandler: ((Error) -> Void)?
    let fileSystem: any FileSystem
    private var requestID = UUID()
    private var loadTask: Task<Void, Never>?
    init(path: URL, fileSystem: any FileSystem) { self.path = path; pathText = path.path; self.fileSystem = fileSystem }
    var selectedEntries: [FileEntry] { entries.filter { selection.contains($0.id) } }
    var selectedSize: Int64 { selectedEntries.reduce(0) { total, entry in
        let (sum, overflow) = total.addingReportingOverflow(max(0, entry.size ?? 0))
        return overflow ? Int64.max : sum
    } }
    var parentEntry: FileEntry {
        FileEntry(url: path.appendingPathComponent("..", isDirectory: true), name: "..",
                  isDirectory: true, isSymbolicLink: false, size: nil, modified: nil,
                  type: "На уровень выше", isParent: true)
    }
    func focusFirstEntry() {
        selection = [parentEntry.id]
        selectFirstOnLoad = loading
        focusRequest = UUID()
    }
    var sortedEntries: [FileEntry] {
        [parentEntry] + entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            let comparison: ComparisonResult
            switch sort {
            case .name: comparison = lhs.name.localizedStandardCompare(rhs.name)
            case .size: comparison = (lhs.size ?? -1) == (rhs.size ?? -1) ? .orderedSame : ((lhs.size ?? -1) < (rhs.size ?? -1) ? .orderedAscending : .orderedDescending)
            case .modified: comparison = (lhs.modified ?? .distantPast).compare(rhs.modified ?? .distantPast)
            case .type: comparison = lhs.type.localizedStandardCompare(rhs.type)
            }
            let result = comparison == .orderedSame ? lhs.name.localizedStandardCompare(rhs.name) : comparison
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }
    func stop() { requestID = UUID(); loadTask?.cancel(); loading = false }
    func navigate(to url: URL, showHidden: Bool) {
        stop()
        let token = UUID(); requestID = token; loading = true
        loadTask = Task { [weak self, fileSystem] in
            do {
                let snapshot = try await fileSystem.contents(at: url, showHidden: showHidden)
                guard let self, !Task.isCancelled, requestID == token else { return }
                let same = path == snapshot.url
                path = snapshot.url; pathText = path.path; entries = snapshot.entries
                if selectFirstOnLoad || !same {
                    selection = [parentEntry.id]
                    focusRequest = UUID()
                } else {
                    selection = selection.intersection(Set(entries.map(\.id) + [parentEntry.id]))
                }
                selectFirstOnLoad = false
                revision = UUID(); loading = false
            } catch {
                guard let self, !Task.isCancelled, requestID == token else { return }
                loading = false; pathText = path.path; errorHandler?(error)
            }
        }
    }
}
