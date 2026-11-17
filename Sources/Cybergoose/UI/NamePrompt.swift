import SwiftUI
import AppKit

@MainActor
final class InitiallySelectedTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            window?.makeFirstResponder(self); selectText(nil)
        }
    }
}

struct SelectedNameField: NSViewRepresentable {
    @Binding var text: String
    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
    func makeNSView(context: Context) -> NSTextField {
        let field = InitiallySelectedTextField(string: text)
        field.placeholderString = "Имя"
        field.delegate = context.coordinator
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            field.selectText(nil)
        }
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {}
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSTextField { text.wrappedValue = field.stringValue }
        }
    }
}

struct NamePrompt: View {
    @Bindable var model: WorkspaceModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Создать каталог").font(.headline)
            SelectedNameField(text: $model.proposedName).frame(height: 24)
            HStack {
                Button("Отмена", role: .cancel) { model.showNamePrompt = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Создать") { model.applyName(); model.showNamePrompt = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 380)
    }
}
