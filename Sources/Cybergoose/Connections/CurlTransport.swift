import Foundation
import CCurlBridge

struct TransportFailure: LocalizedError, Sendable {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

struct TransportResponse: Sendable {
    let status: Int
    let bytes: UInt64
    let headers: [String: String]
}

protocol RequestTransport: Sendable {
    func cancel()
    func request(url: String, user: String, secret: String, signature: String, tls: Bool,
                 method: String, headers: [String], commands: [String], input: URL?, output: URL,
                 cancellation: CancellationFlag, progress: @escaping @Sendable (UInt64) -> Void) async throws -> TransportResponse
}

// All libcurl work and file IO runs on a serial utility queue. cancel() only sets
// an atomic flag read by libcurl's progress callback; handles never cross queues.
final class CurlTransport: RequestTransport, @unchecked Sendable {
    private let handle: OpaquePointer
    private let queue = DispatchQueue(label: "app.cybergoose.curl", qos: .utility)
    init() throws {
        guard let handle = cg_curl_create() else { throw ClientError.message("Не удалось создать транспорт libcurl.") }
        self.handle = handle
    }
    deinit { cg_curl_free(handle) }
    func cancel() { cg_curl_cancel(handle) }
    func request(url: String, user: String, secret: String, signature: String = "", tls: Bool = false,
                 method: String = "GET", headers: [String] = [], commands: [String] = [],
                 input: URL? = nil, output: URL, cancellation: CancellationFlag = CancellationFlag(),
                 progress: @escaping @Sendable (UInt64) -> Void = { _ in }) async throws -> TransportResponse {
        guard !headers.contains(where: { $0.contains("\r") || $0.contains("\n") }),
              !commands.contains(where: { $0.contains("\r") || $0.contains("\n") || $0.contains("\0") }),
              ![user, secret].contains(where: { $0.contains("\0") }) else {
            throw ClientError.message("Недопустимые управляющие символы в параметрах запроса.")
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    try cancellation.check()
                    let callback = CurlProgress(cancellation: cancellation, progress: progress)
                    let code = cg_curl_request(handle, url, user, secret, signature, tls ? 1 : 0, method,
                        headers.joined(separator: "\n"), commands.joined(separator: "\n"), input?.path ?? "", output.path,
                        { bytes, pointer in
                            guard let pointer else { return 1 }
                            return Unmanaged<CurlProgress>.fromOpaque(pointer).takeUnretainedValue().report(bytes)
                        }, Unmanaged.passUnretained(callback).toOpaque())
                    withExtendedLifetime(callback) {}
                    try cancellation.check()
                    guard code == 0 else {
                        throw TransportFailure(status: Int(cg_curl_status(handle)), message: "Сетевая операция: \(String(cString: cg_curl_error(handle)))")
                    }
                    var responseHeaders: [String: String] = [:]
                    for line in String(cString: cg_curl_headers(handle)).components(separatedBy: "\r\n") {
                        guard let colon = line.firstIndex(of: ":") else { continue }
                        responseHeaders[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    }
                    continuation.resume(returning: TransportResponse(status: Int(cg_curl_status(handle)), bytes: cg_curl_bytes(handle), headers: responseHeaders))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cybergoose-network-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }
    static func encode(_ value: String, slash: Bool = false) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~" + (slash ? "/" : "")))!
    }
}

private final class CurlProgress {
    let cancellation: CancellationFlag
    let progress: @Sendable (UInt64) -> Void
    private var last = Date.distantPast
    init(cancellation: CancellationFlag, progress: @escaping @Sendable (UInt64) -> Void) { self.cancellation = cancellation; self.progress = progress }
    func report(_ bytes: UInt64) -> Int32 {
        do { try cancellation.check() } catch { return 1 }
        if Date().timeIntervalSince(last) > 0.1 { last = Date(); progress(bytes) }
        return 0
    }
}
