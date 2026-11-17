import Foundation

final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    func check() throws { lock.lock(); let cancelled = value; lock.unlock(); if cancelled { throw CancellationError() } }
}

