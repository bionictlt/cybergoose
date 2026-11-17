import Foundation
import Observation

@MainActor @Observable
final class ConnectionManager {
    enum State: String { case disconnected = "Нет подключения", connecting = "Соединение…", verifying = "Проверка ключа…", authenticating = "Авторизация…", connected = "Подключено" }
    var state = State.disconnected
    var profile: ConnectionProfile?
    var trustRequest: HostTrustRequest?
    private(set) var connection: (any RemoteConnection)?
    var onConnected: ((ConnectionProfile, any RemoteConnection, RemotePath) -> Void)?
    var onDisconnected: (() -> Void)?
    var onError: ((Error) -> Void)?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var trustContinuation: CheckedContinuation<Bool, Never>?
    var busy: Bool { state != .disconnected && state != .connected }

    func connect(_ profile: ConnectionProfile, secret: String) {
        disconnect()
        let token = UUID(); generation = token
        self.profile = profile; state = .connecting
        task = Task {
            do {
                if !profile.transferProtocol.isSSH {
                    let connection: any RemoteConnection
                    let path: RemotePath
                    if profile.transferProtocol == .s3 {
                        let remote = try S3Connection(profile: profile, secret: secret)
                        connection = remote; self.connection = remote
                        path = try await remote.connect()
                    } else {
                        let remote = try FTPConnection(profile: profile, secret: secret)
                        connection = remote; self.connection = remote
                        path = try await remote.connect()
                    }
                    guard !Task.isCancelled, generation == token else { return }
                    state = .connected; onConnected?(profile, connection, path)
                    return
                }
                let connection = try SSHConnection(useSCP: profile.transferProtocol == .scp)
                self.connection = connection
                let identity = try await connection.handshake(profile)
                guard !Task.isCancelled, generation == token else { return }
                let trusted = try KnownHostsStore().check(identity, for: profile)
                if !trusted {
                    state = .verifying
                    let accepted = await withCheckedContinuation { continuation in
                        trustContinuation = continuation
                        trustRequest = HostTrustRequest(profile: profile, identity: identity)
                    }
                    guard accepted, !Task.isCancelled, generation == token else { return }
                }
                state = .authenticating
                let path = try await connection.authenticate(profile, secret: secret)
                guard !Task.isCancelled, generation == token else { return }
                state = .connected
                onConnected?(profile, connection, path)
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                disconnect(); onError?(error)
            }
        }
    }
    func answerTrust(_ accept: Bool, remember: Bool = false) {
        guard let request = trustRequest else { return }
        if accept && remember {
            do { try KnownHostsStore().trust(request.identity, for: request.profile) }
            catch { disconnect(); onError?(error); return }
        }
        let continuation = trustContinuation
        trustContinuation = nil; trustRequest = nil
        if !accept { disconnect() }
        continuation?.resume(returning: accept)
    }
    func disconnect() {
        generation = UUID(); task?.cancel(); task = nil
        connection?.cancel(); connection = nil
        trustRequest = nil
        let continuation = trustContinuation; trustContinuation = nil
        continuation?.resume(returning: false)
        state = .disconnected; profile = nil
        onDisconnected?()
    }
}
