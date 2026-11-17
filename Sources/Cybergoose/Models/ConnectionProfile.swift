import Foundation

enum AuthenticationMethod: String, Codable, CaseIterable, Sendable {
    case password, privateKey
    var title: String { self == .password ? "Пароль" : "SSH-ключ" }
}

enum TransferProtocol: String, Codable, CaseIterable, Sendable {
    case sftp, ftp, ftps, ftpsImplicit, s3, scp
    var title: String {
        switch self {
        case .sftp: "SFTP"
        case .ftp: "FTP"
        case .ftps: "FTPS (explicit TLS)"
        case .ftpsImplicit: "FTPS (implicit TLS)"
        case .s3: "S3"
        case .scp: "SCP"
        }
    }
    var isSSH: Bool { self == .sftp || self == .scp }
    var defaultPort: Int {
        switch self { case .sftp, .scp: 22; case .ftp, .ftps: 21; case .ftpsImplicit: 990; case .s3: 443 }
    }
}

struct ConnectionProfile: Identifiable, Codable, Sendable {
    var id = UUID().uuidString
    var name = ""
    var host = ""
    var port = 22
    var username = NSUserName()
    var authentication: AuthenticationMethod = .password
    var privateKeyPath = ""
    var initialPath = "."
    var transferProtocol: TransferProtocol = .sftp
    var bucket = ""
    var region = "us-east-1"
    var virtualHosted = false
    var endpoint: String { "\(host):\(port)" }
    // Include the namespace so queued edits cannot be redirected to another bucket/protocol.
    var resourceIdentity: String { "\(transferProtocol.rawValue)|\(endpoint)|\(bucket)|\(region)|\(virtualHosted)" }

    init() {}
    enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, authentication, privateKeyPath, initialPath
        case transferProtocol, bucket, region, virtualHosted
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(Int.self, forKey: .port)
        username = try c.decode(String.self, forKey: .username)
        authentication = try c.decode(AuthenticationMethod.self, forKey: .authentication)
        privateKeyPath = try c.decode(String.self, forKey: .privateKeyPath)
        initialPath = try c.decode(String.self, forKey: .initialPath)
        transferProtocol = try c.decodeIfPresent(TransferProtocol.self, forKey: .transferProtocol) ?? .sftp
        bucket = try c.decodeIfPresent(String.self, forKey: .bucket) ?? ""
        region = try c.decodeIfPresent(String.self, forKey: .region) ?? "us-east-1"
        virtualHosted = try c.decodeIfPresent(Bool.self, forKey: .virtualHosted) ?? false
    }
    func validated() throws -> Self {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        copy.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let controls = CharacterSet.controlCharacters
        guard !copy.host.isEmpty, !copy.username.isEmpty, (1...65535).contains(port),
              !copy.host.contains("/"), !copy.host.contains("@"), !copy.host.contains("?"), !copy.host.contains("#"),
              !copy.host.contains(where: { $0.isWhitespace }),
              ![copy.host, copy.username, initialPath, privateKeyPath, bucket, region].contains(where: { $0.rangeOfCharacter(from: controls) != nil }) else {
            throw ClientError.message("Укажите хост без схемы, имя пользователя и порт от 1 до 65535. Управляющие символы недопустимы.")
        }
        var url = URLComponents(); url.scheme = "https"; url.host = copy.host; url.port = port
        guard url.url?.host != nil else { throw ClientError.message("Некорректный хост.") }
        if copy.name.isEmpty { copy.name = copy.endpoint }
        if copy.initialPath.isEmpty || (!transferProtocol.isSSH && copy.initialPath == ".") { copy.initialPath = transferProtocol.isSSH ? "." : "/" }
        if !transferProtocol.isSSH {
            guard copy.initialPath.hasPrefix("/") else { throw ClientError.message("Начальный каталог должен начинаться с /.") }
            copy.authentication = .password; copy.privateKeyPath = ""
        }
        if transferProtocol == .s3 {
            copy.bucket = bucket.trimmingCharacters(in: .whitespacesAndNewlines)
            copy.region = region.trimmingCharacters(in: .whitespacesAndNewlines)
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")
            guard !copy.bucket.isEmpty, copy.bucket.rangeOfCharacter(from: allowed.inverted) == nil,
                  !copy.region.isEmpty, copy.region.rangeOfCharacter(from: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").inverted) == nil else {
                throw ClientError.message("Укажите имя S3 bucket и регион (например us-east-1 или auto).")
            }
        }
        if transferProtocol.isSSH && authentication == .privateKey {
            copy.privateKeyPath = NSString(string: privateKeyPath).expandingTildeInPath
            guard copy.privateKeyPath.hasPrefix("/"), FileManager.default.isReadableFile(atPath: copy.privateKeyPath) else {
                throw ClientError.message("Выберите доступный файл закрытого SSH-ключа.")
            }
        }
        return copy
    }
}

enum ClientError: LocalizedError, Sendable {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { text } else { nil } }
}

struct RemotePath: Hashable, Sendable {
    let value: String
    init(_ value: String) throws {
        guard value.hasPrefix("/"), !value.contains("\0") else { throw ClientError.message("Нужен абсолютный удалённый путь.") }
        // Do not collapse '..': the preceding component may be a symbolic link.
        self.value = value
    }
    func child(_ name: String) throws -> Self {
        try Self.validateName(name)
        return try Self((value == "/" ? "" : value) + "/" + name)
    }
    static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw ClientError.message("Имя не должно содержать /, нулевой символ или состоять из . либо ...")
        }
    }
    var url: URL {
        var components = URLComponents()
        components.scheme = "sftp"
        components.host = "remote"
        components.path = value
        return components.url!
    }
}
