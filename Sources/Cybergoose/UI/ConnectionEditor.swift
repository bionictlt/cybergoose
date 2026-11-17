import SwiftUI
import UniformTypeIdentifiers

struct ConnectionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var profile: ConnectionProfile
    @State var secret: String
    @State var remember: Bool
    @State private var sessionToken = ""
    @State private var choosingKey = false
    @State private var saving = false
    @State private var errorMessage: String?
    var warning: String?
    let save: (ConnectionProfile, String, Bool, Bool) async throws -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Подключение к серверу").font(.headline)
            Form {
                TextField("Название", text: $profile.name)
                Picker("Протокол", selection: $profile.transferProtocol) {
                    ForEach(TransferProtocol.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                TextField("Хост", text: $profile.host, prompt: Text("server.example.com"))
                TextField("Порт", value: $profile.port, format: .number.grouping(.never))
                TextField(profile.transferProtocol == .s3 ? "Access Key ID" : "Пользователь", text: $profile.username)
                if [.ftp, .ftps, .ftpsImplicit].contains(profile.transferProtocol) {
                    Button("Гостевые реквизиты") {
                        profile.username = "anonymous"
                        profile.authentication = .password
                        secret = "anonymous@"
                        remember = false
                    }
                    .help("Заполнить логин anonymous и гостевой пароль anonymous@")
                }
                if profile.transferProtocol == .s3 {
                    TextField("Bucket", text: $profile.bucket)
                    TextField("Регион", text: $profile.region)
                    Toggle("Bucket в поддомене endpoint", isOn: $profile.virtualHosted)
                }
                if profile.transferProtocol.isSSH {
                    Picker("Авторизация", selection: $profile.authentication) {
                    ForEach(AuthenticationMethod.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if profile.authentication == .privateKey {
                    HStack {
                        TextField("Закрытый ключ", text: $profile.privateKeyPath, prompt: Text("~/.ssh/id_ed25519"))
                        Button("Выбрать…") { choosingKey = true }
                    }
                }
                }
                SecureField(profile.transferProtocol == .s3 ? "Secret Access Key" : (profile.authentication == .password ? "Пароль" : "Passphrase"), text: $secret)
                if profile.transferProtocol == .s3 {
                    SecureField("Session Token", text: $sessionToken)
                }
                Toggle("Сохранить в Keychain", isOn: $remember)
                TextField("Начальный каталог", text: $profile.initialPath)
            }.textFieldStyle(.roundedBorder)
            Text(protocolHint)
                .font(.caption).foregroundStyle(.secondary)
            if let warning { Text(warning).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("Отмена", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Сохранить") { submit(connect: false) }
                Button("Подключиться") { submit(connect: true) }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 540)
        .onAppear {
            if profile.transferProtocol == .s3 {
                let credentials = S3Credentials.decode(secret)
                secret = credentials.secretKey; sessionToken = credentials.sessionToken
            }
        }
        .onChange(of: profile.transferProtocol) { old, selected in
            if profile.port == old.defaultPort { profile.port = selected.defaultPort }
            if profile.initialPath == "." || profile.initialPath == "/" { profile.initialPath = selected.isSSH ? "." : "/" }
            // A saved password must never be sent to a different protocol by accident.
            secret = ""; sessionToken = ""; remember = false
            if !selected.isSSH { profile.authentication = .password }
        }
        .disabled(saving)
        .interactiveDismissDisabled(saving)
        .alert("Не удалось сохранить подключение", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .fileImporter(isPresented: $choosingKey, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { profile.privateKeyPath = url.path }
        }
    }
    private var protocolHint: String {
        switch profile.transferProtocol {
        case .sftp: "«.» — домашний каталог. При первом подключении сверьте fingerprint SSH-ключа."
        case .scp: "Файлы передаются через SCP; для каталогов и файловых команд требуется SFTP на том же SSH-сервере. При первом подключении сверьте fingerprint."
        case .ftp: "FTP передаёт пароль и файлы без шифрования. По возможности выберите FTPS. Каталоги задаются абсолютным путём от /."
        case .ftps, .ftpsImplicit: "TLS обязателен для команд и данных. Сертификат сервера проверяется. Каталоги задаются абсолютным путём от /."
        case .s3: "Хост — endpoint без https:// и bucket (например s3.eu-central-1.amazonaws.com). Начальный каталог — / или /префикс. HTTPS и Signature V4. До 5 GiB на файл; переименование каталогов-префиксов пока недоступно. Секрет и Session Token сохраняются только в Keychain."
        }
    }
    private func submit(connect: Bool) {
        guard !saving else { return }
        saving = true
        Task {
            do {
                let value = profile.transferProtocol == .s3 ? try S3Credentials(secretKey: secret, sessionToken: sessionToken).encoded() : secret
                try await save(profile, value, remember, connect)
            }
            catch { errorMessage = error.localizedDescription }
            saving = false
        }
    }
}
