import Foundation
import Observation

enum ConflictChoice: Sendable { case overwrite, overwriteAll, skip, cancel }
struct FileConflict: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let detail: String
    let allowsAll: Bool
}

@MainActor @Observable
final class QueuedOperation: Identifiable {
    enum State: String { case waiting = "Ожидает", running = "Выполняется", done = "Готово", failed = "Ошибка", cancelled = "Отменено" }
    let id = UUID()
    let title: String
    let batch: UUID
    var state = State.waiting
    var bytes: UInt64 = 0
    var total: Int64 = 0
    var error: String?
    let cancellation = CancellationFlag()
    var action: (@MainActor (QueuedOperation) async throws -> Void)?
    init(title: String, batch: UUID, action: @escaping @MainActor (QueuedOperation) async throws -> Void) {
        self.title = title; self.batch = batch; self.action = action
    }
}

@MainActor @Observable
final class FileOperationQueue {
    var jobs: [QueuedOperation] = []
    var conflict: FileConflict?
    private var answer: CheckedContinuation<ConflictChoice, Never>?
    private var runner: Task<Void, Never>?
    private var overwriteBatches: Set<UUID> = []
    var onChange: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    var running: QueuedOperation? { jobs.first { $0.state == .running } }
    var busy: Bool { jobs.contains { $0.state == .waiting || $0.state == .running } }
    var waitingCount: Int { jobs.filter { $0.state == .waiting }.count }
    @discardableResult
    func enqueue(_ title: String, batch: UUID = UUID(), action: @escaping @MainActor (QueuedOperation) async throws -> Void) -> QueuedOperation {
        let job = QueuedOperation(title: title, batch: batch, action: action)
        jobs.append(job); start(); return job
    }
    private func start() {
        guard runner == nil else { return }
        runner = Task { [weak self] in
            guard let self else { return }
            while let job = jobs.first(where: { $0.state == .waiting }) {
                job.state = .running
                do {
                    try job.cancellation.check()
                    if let action = job.action { try await action(job) }
                    job.state = .done
                    job.action = nil // Finished history must not retain SSH sessions or captured data.
                } catch is CancellationError { job.state = .cancelled }
                catch {
                    job.state = .failed; job.error = error.localizedDescription
                    onFailure?(error)
                }
                onChange?()
            }
            overwriteBatches.removeAll(); runner = nil
        }
    }
    func resolve(_ conflict: FileConflict, batch: UUID) async throws -> ConflictChoice {
        if overwriteBatches.contains(batch) && conflict.allowsAll { return .overwrite }
        self.conflict = conflict
        let result = await withCheckedContinuation { answer = $0 }
        if result == .cancel { throw CancellationError() }
        if result == .overwriteAll { overwriteBatches.insert(batch) }
        return result
    }
    func answerConflict(_ result: ConflictChoice) {
        let continuation = answer; answer = nil; conflict = nil
        continuation?.resume(returning: result)
    }
    func cancel(_ job: QueuedOperation) {
        job.cancellation.cancel()
        if job.state == .waiting { job.state = .cancelled }
        if job.state == .running { answerConflict(.cancel) }
    }
    func cancelAll() { for job in jobs { cancel(job) }; answerConflict(.cancel) }
    func retry(_ job: QueuedOperation) {
        guard job.state == .failed || job.state == .cancelled else { return }
        if let action = job.action { enqueue(job.title, action: action) }
    }
    func clearFinished() { jobs.removeAll { $0.state != .running && $0.state != .waiting } }
}
