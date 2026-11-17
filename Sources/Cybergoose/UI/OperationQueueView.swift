import SwiftUI

struct OperationQueueView: View {
    @Bindable var model: WorkspaceModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Очередь операций").font(.headline)
                Spacer()
                Button("Очистить завершённые") { model.queue.clearFinished() }
                Button("Закрыть") { model.showQueue = false }.keyboardShortcut(.cancelAction)
            }
            if let conflict = model.queue.conflict {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Файл «\(conflict.name)» уже существует").fontWeight(.semibold)
                    Text(conflict.detail).font(.caption)
                    HStack {
                        Button("Отменить задание") { model.queue.answerConflict(.cancel) }
                        Button("Пропустить") { model.queue.answerConflict(.skip) }
                        Button("Перезаписать") { model.queue.answerConflict(.overwrite) }
                        if conflict.allowsAll { Button("Перезаписать все") { model.queue.answerConflict(.overwriteAll) } }
                    }
                }.padding(10).background(.quaternary).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            List {
                ForEach(model.queue.jobs) { job in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(job.title); Spacer(); Text(job.state.rawValue).foregroundStyle(.secondary)
                            if job.state == .running || job.state == .waiting { Button("Отменить") { model.queue.cancel(job) } }
                            if job.state == .failed || job.state == .cancelled { Button("Повторить") { model.queue.retry(job) } }
                        }
                        if job.state == .running { ProgressView(value: Double(job.bytes), total: Double(max(1, job.total))) }
                        if let error = job.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    }.padding(.vertical, 4)
                }
                if !model.documents.sessions.isEmpty {
                    Section("Удалённые файлы в редакторе") {
                        ForEach(model.documents.sessions) { session in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.remoteURL.path)
                                Text(session.status).font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Button("Показать локальную копию") { NSWorkspace.shared.activateFileViewerSelecting([session.localURL]) }
                                    if session.watching { Button("Завершить наблюдение") { model.documents.stop(session) } }
                                }
                            }
                        }
                    }
                }
            }.listStyle(.inset)
        }.padding(16).frame(minWidth: 650, idealWidth: 750, minHeight: 380)
    }
}
