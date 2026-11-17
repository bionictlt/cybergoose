import AppKit
import SwiftUI

@main
struct CybergooseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = WorkspaceModel()
    var body: some Scene {
        Window("Cybergoose", id: "main") {
            WorkspaceView(model: model)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1120, height: 680)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("О программе Cybergoose") {
                    let website = URL(string: "https://msafi.ru/cybergoose")!
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.alignment = .center
                    let credits = NSAttributedString(string: website.absoluteString, attributes: [
                        .link: website,
                        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                        .foregroundColor: NSColor.linkColor,
                        .paragraphStyle: paragraph
                    ])
                    NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
                }
            }
            CommandGroup(after: .newItem) {
                Button("Новое подключение…") { model.newConnection() }.keyboardShortcut("n")
                Button("Переименовать…") { model.requestRename() }.keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Домашний каталог") { model.home() }.keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Показать скрытые файлы") { model.showHidden.toggle() }.keyboardShortcut(".", modifiers: [.command, .shift])
            }
        }
        Settings {
            Form {
                Text("Cybergoose — файловый клиент").font(.headline)
                Toggle("Показывать скрытые файлы", isOn: $model.showHidden)
                Text("Tab — сменить панель; ⌘↓ — открыть; ⌘↑ — вверх; Enter — переименовать; Пробел — Quick Look; F4 — редактор; ⌘R — обновить. Для F-клавиш macOS может требовать Fn.")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(24).frame(width: 430)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: WorkspaceModel?
    private var keyMonitor: Any?
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let model = self?.model, NSApp.keyWindow?.identifier?.rawValue == "main" || NSApp.keyWindow?.title == "Cybergoose",
                  !(NSApp.keyWindow?.firstResponder is NSTextView), NSApp.modalWindow == nil,
                  NSApp.keyWindow?.attachedSheet == nil else { return event }
            if event.keyCode == 48, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                model.togglePanel(); return nil
            }
            let functions: [UInt16: Int] = [99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8, 109: 10]
            if let key = functions[event.keyCode] { model.perform(key); return nil }
            if model.activePanel == .remote, model.remote == nil, event.keyCode == 36 { model.beginConnect(); return nil }
            return event
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model?.isOperating == true || model?.documents.hasPending == true {
            let alert = NSAlert()
            alert.messageText = "Прервать передачу и закрыть Cybergoose?"
            alert.informativeText = "В очереди могут оставаться задания и изменения редактора. Локальные копии редактируемых файлов сохранятся в Application Support/CyberGoose/Editing."
            alert.addButton(withTitle: "Продолжить передачу")
            alert.addButton(withTitle: "Прервать и закрыть")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        model?.disconnect()
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
