import SwiftUI

struct WorkspaceView: View {
    @Bindable var model: WorkspaceModel
    @FocusState private var bookmarksFocused: Bool
    @State private var bookmarkToDelete: ConnectionProfile?
    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                filePanel(model.local, side: .local).frame(minWidth: 350)
                Group {
                    if let remote = model.remote { filePanel(remote, side: .remote) }
                    else { bookmarksPanel }
                }.frame(minWidth: 350)
            }
            if let title = model.operationTitle {
                Divider()
                HStack {
                    Text(title).font(.caption)
                    ProgressView(value: Double(model.transferred), total: Double(max(1, model.transferTotal))).frame(maxWidth: 200)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: model.transferred), countStyle: .file)).font(.caption).monospacedDigit()
                    Spacer()
                    Button("Отменить задание") { if let job = model.queue.running { model.queue.cancel(job) } }.controlSize(.small)
                }.padding(.horizontal, 10).frame(height: 32)
            }
            if model.queue.busy || model.queue.jobs.contains(where: { $0.state == .failed }) {
                HStack {
                    Text("В очереди: \(model.queue.waitingCount)").font(.caption)
                    if let failed = model.queue.jobs.last(where: { $0.state == .failed }) { Text(failed.error ?? "Ошибка").font(.caption).foregroundStyle(.red).lineLimit(1) }
                    Spacer()
                    Button("Показать очередь") { model.showQueue = true }.controlSize(.small)
                }.padding(.horizontal, 10).frame(height: 26)
            }
            Divider()
            HStack {
                Text("Выбрано: \(model.active?.selectedEntries.count ?? 0) · \(ByteCountFormatter.string(fromByteCount: model.active?.selectedSize ?? 0, countStyle: .file))")
                Spacer()
                if model.active?.loading == true || model.connections.busy { ProgressView().controlSize(.mini) }
                Text("\(model.active?.entries.count ?? 0) объектов")
                Divider().frame(height: 12)
                Label(model.connectionStatus, systemImage: "network").lineLimit(1)
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 10).frame(height: 27)
            Divider()
            HStack(spacing: 1) {
                functionButton(3, "Просмотр"); functionButton(4, "Редактор"); functionButton(5, "Копировать"); functionButton(6, "Переместить")
                functionButton(7, "Каталог"); functionButton(8, "Удалить")
                functionButton(10, model.connections.state == .disconnected ? "Закрыть" : "Отключиться")
            }.padding(5)
        }
        .frame(minWidth: 820, minHeight: 440)
        .toolbar {
            ToolbarItemGroup {
                Button { model.showQueue = true } label: { Label("Очередь", systemImage: "list.bullet.rectangle") }
                Button { model.beginConnect() } label: { Label("Подключиться", systemImage: "externaldrive.connected.to.line.below") }.disabled(!model.canConnect)
                Button { model.disconnect() } label: { Label("Отключиться", systemImage: "eject") }.disabled(model.connections.state == .disconnected)
                Button { model.refresh() } label: { Label("Обновить", systemImage: "arrow.clockwise") }.keyboardShortcut("r").disabled(model.isOperating)
                Toggle(isOn: $model.showHidden) { Label("Скрытые файлы", systemImage: "eye") }
                SettingsLink { Label("Настройки", systemImage: "gearshape") }
            }
        }
        .onChange(of: model.activePanel) { bookmarksFocused = model.activePanel == .remote && model.remote == nil }
        .onChange(of: model.showHidden) { model.refreshBoth() }
        .task { model.start() }
        .sheet(item: $model.connectionDraft, onDismiss: { model.connectionEditorDismissed() }) { profile in
            ConnectionEditor(profile: profile, secret: model.draftSecret, remember: model.draftRemember, warning: model.draftWarning) { profile, secret, remember, connect in
                try await model.saveConnection(profile, secret: secret, remember: remember, connect: connect)
            }
        }
        .alert("Cybergoose", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .alert("Неизвестный SSH-сервер", isPresented: Binding(get: { model.connections.trustRequest != nil }, set: { _ in })) {
            Button("Отмена", role: .cancel) { model.connections.answerTrust(false) }
            Button("Доверять один раз") { model.connections.answerTrust(true) }
            Button("Доверять и сохранить") { model.connections.answerTrust(true, remember: true) }
        } message: {
            if let request = model.connections.trustRequest {
                Text("\(request.profile.endpoint)\n\(request.identity.algorithm)\n\(request.identity.fingerprint)\n\nСверьте fingerprint с администратором по независимому каналу перед отправкой учётных данных.")
            }
        }
        .sheet(isPresented: $model.showNamePrompt) { NamePrompt(model: model) }
        .sheet(isPresented: $model.showQueue) { OperationQueueView(model: model) }
        .alert("Файл «\(model.queue.conflict?.name ?? "")» уже существует", isPresented: Binding(get: { model.queue.conflict != nil && !model.showQueue && !model.showNamePrompt && model.connectionDraft == nil }, set: { _ in })) {
            Button("Отменить задание", role: .cancel) { model.queue.answerConflict(.cancel) }
            Button("Пропустить") { model.queue.answerConflict(.skip) }
            Button("Перезаписать", role: .destructive) { model.queue.answerConflict(.overwrite) }
            if model.queue.conflict?.allowsAll == true { Button("Перезаписать все", role: .destructive) { model.queue.answerConflict(.overwriteAll) } }
        } message: { Text(model.queue.conflict?.detail ?? "") }
        .confirmationDialog("Удалить с сервера без возможности восстановления?", isPresented: Binding(get: { model.deletion != nil }, set: { if !$0 { model.deletion = nil } }), titleVisibility: .visible) {
            if let request = model.deletion {
                Button("Удалить \(request.entries.count) объектов", role: .destructive) { model.delete(request); model.deletion = nil }
            }
            Button("Отмена", role: .cancel) { model.deletion = nil }
        } message: { Text("Удаляются файлы и пустые каталоги. Непустые каталоги не удаляются рекурсивно.") }
        .confirmationDialog("Удалить закладку и её секрет из Keychain?", isPresented: Binding(get: { bookmarkToDelete != nil }, set: { if !$0 { bookmarkToDelete = nil } }), titleVisibility: .visible) {
            if let profile = bookmarkToDelete { Button("Удалить закладку", role: .destructive) { model.deleteBookmark(profile); bookmarkToDelete = nil } }
        }
    }
    private func header(_ title: String, side: PanelSide, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon); Text(title).fontWeight(.semibold); Spacer()
            if model.activePanel == side { Circle().fill(Color.accentColor).frame(width: 6, height: 6) }
        }.font(.system(size: 12)).padding(.horizontal, 10).frame(height: 28)
            .background(model.activePanel == side ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
            .contentShape(Rectangle()).onTapGesture { model.activePanel = side }
    }
    private func filePanel(_ panel: PanelModel, side: PanelSide) -> some View {
        @Bindable var panel = panel
        return VStack(spacing: 0) {
            header(side == .local ? "Локальные файлы" : (model.connections.profile?.name ?? "SFTP"), side: side, icon: side == .local ? "internaldrive" : "server.rack")
            HStack(spacing: 5) {
                Button { model.parent(side) } label: { Image(systemName: "arrow.up") }.help("Родительский каталог — ⌘↑")
                if side == .local {
                    Button { model.home() } label: { Image(systemName: "house") }.help("Домашний каталог")
                } else {
                    Button { model.disconnect() } label: { Image(systemName: "bookmark") }.help("Отключиться и вернуться к закладкам")
                }
                TextField("Путь", text: $panel.pathText).textFieldStyle(.roundedBorder)
                    .onSubmit { model.submitPath(side); NSApp.keyWindow?.makeFirstResponder(nil) }
            }.controlSize(.small).padding(6)
            Divider()
            FileTableView(model: panel, workspace: model, side: side)
                .contextMenu {
                    Button("Предпросмотр (Пробел)") { model.activePanel = side; model.previewSelection() }
                    Button("Открыть в текстовом редакторе (F4)") { model.activePanel = side; model.editSelection() }
                    Divider()
                    Button("Копировать (F5)") { model.activePanel = side; model.copySelection() }
                    Button("Переместить (F6)") { model.activePanel = side; model.copySelection(move: true) }
                    Button("Переименовать (Enter)") { model.activePanel = side; model.requestRename() }
                    Button("Создать каталог (F7)") { model.activePanel = side; model.promptName(rename: false) }
                    if side == .remote { Button("Удалить…", role: .destructive) { model.activePanel = side; model.confirmDelete() } }
                }

        }
    }
    private var bookmarksPanel: some View {
        VStack(spacing: 0) {
            header("Серверы", side: .remote, icon: "server.rack")
            HStack {
                Text("Сохранённые подключения").foregroundStyle(.secondary)
                Spacer()
                Button { model.newConnection() } label: { Image(systemName: "plus") }.help("Новое подключение")
            }.font(.system(size: 11)).controlSize(.small).padding(.horizontal, 10).frame(height: 34)
            Divider()
            if model.profiles.isEmpty {
                ContentUnavailableView {
                    Label("Нет подключений", systemImage: "server.rack")
                } description: { Text("Добавьте SFTP, FTP/FTPS, SCP или S3-подключение.") }
                actions: { Button("Добавить сервер…") { model.newConnection() } }
            } else {
                List(model.profiles, selection: $model.selectedBookmark) { profile in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: "externaldrive.connected.to.line.below")
                            Text(profile.name).fontWeight(.medium); Spacer()
                            Text(profile.transferProtocol.title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        }
                        Text("\(profile.username)@\(profile.endpoint)").foregroundStyle(.secondary)
                        Text("\(profile.transferProtocol == .s3 ? profile.bucket : profile.authentication.title) · \(profile.initialPath)").foregroundStyle(.secondary)
                    }.font(.system(size: 12)).padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .tag(profile.id)
                        .simultaneousGesture(TapGesture().onEnded {
                            model.selectedBookmark = profile.id
                            model.activePanel = .remote
                            bookmarksFocused = true
                        })
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            model.selectedBookmark = profile.id
                            model.beginConnect()
                        })
                        .contextMenu {
                            Button("Подключиться") { model.selectedBookmark = profile.id; model.beginConnect() }.disabled(model.connections.busy)
                            Button("Изменить…") { model.editConnection(profile) }
                            Button("Удалить…", role: .destructive) { bookmarkToDelete = profile }
                        }
                }.listStyle(.inset).focused($bookmarksFocused)
            }
            if model.connections.busy {
                HStack { ProgressView().controlSize(.small); Text(model.connectionStatus); Button("Отмена") { model.disconnect() } }.font(.caption).padding(10)
            }
        }
    }
    private func functionButton(_ key: Int, _ title: String) -> some View {
        Button { model.perform(key) } label: {
            HStack(spacing: 5) { Text("F\(key)").foregroundStyle(.secondary).monospaced(); Text(title) }
                .font(.system(size: 11)).frame(maxWidth: .infinity).frame(height: 22)
        }.buttonStyle(.bordered).controlSize(.small)
    }
}
