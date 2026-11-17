import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class CommanderTable: NSTableView {
    var command: ((NSEvent) -> Bool)?
    var activated: (() -> Void)?
    var panelDrag: WorkspaceModel.PanelDrag?
    static let panelEntriesType = NSPasteboard.PasteboardType("app.cybergoose.panel-entries")
    override func mouseDown(with event: NSEvent) { activated?(); super.mouseDown(with: event) }
    override func rightMouseDown(with event: NSEvent) {
        activated?()
        let index = row(at: convert(event.locationInWindow, from: nil))
        if index >= 0 && !selectedRowIndexes.contains(index) { selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        super.rightMouseDown(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if command?(event) == true { return }
        super.keyDown(with: event)
    }
}

@MainActor
final class RenameTextView: NSTextView {
    var ended: (() -> Void)?
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { ended?() }
        return result
    }
}

struct FileTableView: NSViewRepresentable {
    let model: PanelModel
    let workspace: WorkspaceModel
    let side: PanelSide
    func makeCoordinator() -> Coordinator { Coordinator(model: model, workspace: workspace, side: side) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let table = CommanderTable()
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.style = .plain
        table.rowHeight = 23
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for (id, title, width) in [("name", "Имя", 200.0), ("size", "Размер", 75.0), ("modified", "Изменён", 135.0), ("type", "Тип", 90.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = id == "name" ? 120 : 60
            column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            table.addTableColumn(column)
        }
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.openRow)
        table.registerForDraggedTypes([CommanderTable.panelEntriesType])
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
        table.verticalMotionCanBeginDrag = true
        table.activated = { workspace.activePanel = side }
        table.command = { context.coordinator.handle($0) }
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        context.coordinator.table = table
        let menu = NSMenu(title: "Колонки")
        menu.autoenablesItems = false
        menu.delegate = context.coordinator
        table.headerView?.menu = menu
        let hidden = UserDefaults.standard.stringArray(forKey: "columns.hidden.\(side)") ?? []
        for column in table.tableColumns { column.isHidden = hidden.contains(column.identifier.rawValue) }
        if table.tableColumns.allSatisfy(\.isHidden) { table.tableColumns.first?.isHidden = false }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.editingURL == nil && (coordinator.revision != model.revision || coordinator.sort != model.sort || coordinator.ascending != model.ascending) {
            coordinator.revision = model.revision
            coordinator.sort = model.sort
            coordinator.ascending = model.ascending
            coordinator.rows = model.sortedEntries
            coordinator.updating = true
            coordinator.table?.reloadData()
            coordinator.updating = false
        }
        let selected = IndexSet(coordinator.rows.indices.filter { model.selection.contains(coordinator.rows[$0].id) })
        if coordinator.table?.selectedRowIndexes != selected {
            coordinator.updating = true
            coordinator.table?.selectRowIndexes(selected, byExtendingSelection: false)
            coordinator.updating = false
        }
        if let request = workspace.renameRequest, request.side == side, coordinator.lastRename != request.id {
            coordinator.lastRename = request.id
            DispatchQueue.main.async { coordinator.beginRename(request.url) }
        }
        let active = workspace.activePanel == side
        if active, let table = coordinator.table, let window = table.window {
            let requested = coordinator.lastFocusRequest != model.focusRequest
            if requested || ((!coordinator.wasActive || window.firstResponder == nil) && !(window.firstResponder is NSTextView)) {
                window.makeFirstResponder(table)
            }
            if requested {
                if !coordinator.rows.isEmpty { table.scrollRowToVisible(0) }
                coordinator.lastFocusRequest = model.focusRequest
            }
        }
        if !active { coordinator.wasActive = false }
        else if coordinator.table?.window != nil { coordinator.wasActive = true }
    }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate, NSMenuDelegate {
        let model: PanelModel
        let workspace: WorkspaceModel
        let side: PanelSide
        weak var table: NSTableView?
        var rows: [FileEntry] = []
        var revision: UUID?
        var sort: FileSort?
        var ascending = true
        var wasActive = false
        var lastFocusRequest: UUID?
        var updating = false
        var lastRename: UUID?
        var editingURL: URL?
        weak var editingField: NSTextField?
        var editingView: RenameTextView?
        var icons: [String: NSImage] = [:]
        init(model: PanelModel, workspace: WorkspaceModel, side: PanelSide) { self.model = model; self.workspace = workspace; self.side = side }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            guard let column, rows.indices.contains(row) else { return nil }
            let entry = rows[row]
            let id = column.identifier
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? makeCell(id)
            switch id.rawValue {
            case "name":
                cell.textField?.stringValue = entry.name
                if entry.isParent {
                    cell.imageView?.image = NSImage(systemSymbolName: "arrow.turn.up.left", accessibilityDescription: "На уровень выше")
                    cell.toolTip = "Перейти в родительский каталог"
                } else {
                    let key = entry.isDirectory ? "folder" : entry.url.pathExtension.lowercased()
                    if icons[key] == nil { icons[key] = NSWorkspace.shared.icon(for: entry.isDirectory ? .folder : (.init(filenameExtension: key) ?? .data)) }
                    cell.imageView?.image = icons[key]
                    cell.toolTip = entry.url.path
                }
            case "size": cell.textField?.stringValue = entry.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
            case "modified": cell.textField?.stringValue = entry.modified?.formatted(date: .numeric, time: .shortened) ?? "—"
            default: cell.textField?.stringValue = entry.type
            }
            return cell
        }
        func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = id
            let text = NSTextField(frame: .zero)
            text.isEditable = false; text.isSelectable = false
            text.isBezeled = false; text.drawsBackground = false
            text.refusesFirstResponder = false
            text.font = .systemFont(ofSize: 12)
            text.lineBreakMode = .byTruncatingTail
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            cell.textField = text
            var leading = cell.leadingAnchor
            var inset: CGFloat = 5
            if id.rawValue == "name" {
                let icon = NSImageView()
                icon.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(icon)
                cell.imageView = icon
                NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16)])
                leading = icon.trailingAnchor
                inset = 6
            }
            NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: leading, constant: inset), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            return cell
        }
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard editingURL == nil, rows.indices.contains(row), !rows[row].isParent, workspace.canDragFiles(from: side) else { return nil }
            // Private, in-process drags only. Remote URLs are never exported as local files.
            let item = NSPasteboardItem()
            item.setString(rows[row].url.absoluteString, forType: CommanderTable.panelEntriesType)
            return item
        }
        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            let entries = rowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
            (tableView as? CommanderTable)?.panelDrag = workspace.beginFileDrag(entries, from: side)
        }
        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            (tableView as? CommanderTable)?.panelDrag = nil
        }
        private func incomingDrag(_ info: any NSDraggingInfo, to tableView: NSTableView) -> WorkspaceModel.PanelDrag? {
            guard let source = info.draggingSource as? CommanderTable, source !== tableView,
                  let drag = source.panelDrag, workspace.canDropFiles(drag, to: side) else { return nil }
            return drag
        }
        func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo,
                       proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            guard editingURL == nil, incomingDrag(info, to: tableView) != nil else { return [] }
            // Always copy into the directory displayed in the other panel, including
            // when the pointer is over a folder row or an empty table.
            tableView.setDropRow(-1, dropOperation: .on)
            return .copy
        }
        func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo,
                       row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard editingURL == nil, let drag = incomingDrag(info, to: tableView) else { return false }
            return workspace.dropFiles(drag, to: side)
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            model.selection = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
        }
        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key, let sort = FileSort(rawValue: key) else { return }
            model.sort = sort
            model.ascending = descriptor.ascending
        }
        @objc func openRow() {
            guard let table, rows.indices.contains(table.clickedRow) else { return }
            workspace.open(rows[table.clickedRow], side: side)
        }
        func menuWillOpen(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table else { return }
            for column in table.tableColumns {
                let item = NSMenuItem(title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = column.identifier.rawValue
                item.state = column.isHidden ? .off : .on
                item.isEnabled = column.isHidden || table.tableColumns.filter { !$0.isHidden }.count > 1
                menu.addItem(item)
            }
        }
        @objc func toggleColumn(_ item: NSMenuItem) {
            guard let key = item.representedObject as? String, let table,
                  let column = table.tableColumns.first(where: { $0.identifier.rawValue == key }) else { return }
            guard column.isHidden || table.tableColumns.filter({ !$0.isHidden }).count > 1 else { return }
            column.isHidden.toggle()
            UserDefaults.standard.set(table.tableColumns.filter(\.isHidden).map { $0.identifier.rawValue }, forKey: "columns.hidden.\(side)")
        }
        func beginRename(_ url: URL) {
            guard let table, let row = rows.firstIndex(where: { $0.url == url && !$0.isParent }),
                  let column = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "name" }) else { return }
            table.tableColumns[column].isHidden = false
            table.scrollRowToVisible(row)
            guard let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView,
                  let field = cell.textField else { return }
            editingURL = url; editingField = field
            let editor = RenameTextView(frame: field.frame.insetBy(dx: -2, dy: -2))
            editor.string = rows[row].name
            editor.font = .systemFont(ofSize: 12)
            editor.isRichText = false; editor.isEditable = true; editor.isSelectable = true
            editor.drawsBackground = true; editor.backgroundColor = .textBackgroundColor; editor.textColor = .textColor
            editor.textContainerInset = NSSize(width: 2, height: 1)
            editor.textContainer?.lineFragmentPadding = 0
            editor.delegate = self
            editor.ended = { [weak self] in self?.completeEditing(cancelled: false) }
            cell.addSubview(editor)
            field.isHidden = true
            editingView = editor
            table.window?.makeFirstResponder(editor)
            editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
        }
        func completeEditing(cancelled: Bool) {
            guard let url = editingURL, let field = editingField, let editor = editingView else { return }
            let name = editor.string
            editingURL = nil; editingField = nil; editingView = nil
            editor.ended = nil
            table?.window?.makeFirstResponder(table)
            editor.removeFromSuperview(); field.isHidden = false
            guard let entry = rows.first(where: { $0.url == url }) else { return }
            field.stringValue = entry.name
            if !cancelled { workspace.rename(entry, side: side, to: name) }
        }
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == NSSelectorFromString("cancelOperation:") { completeEditing(cancelled: true); return true }
            if selector == NSSelectorFromString("insertNewline:") || selector == NSSelectorFromString("insertTab:") { completeEditing(cancelled: false); return true }
            return false
        }
        func handle(_ event: NSEvent) -> Bool {
            guard workspace.activePanel == side else { return false }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if modifiers == .command {
                if event.keyCode == 126 { workspace.parent(side); return true }
                if event.keyCode == 125 {
                    if let row = table?.selectedRow, rows.indices.contains(row) { workspace.open(rows[row], side: side) }
                    return true
                }
            }
            guard modifiers.isEmpty else { return false }
            switch event.keyCode {
            case 36, 76:
                if let row = table?.selectedRow, rows.indices.contains(row) {
                    if rows[row].isParent { workspace.parent(side) }
                    else { workspace.requestRename(rows[row], side: side) }
                }
                return true
            case 49: workspace.previewSelection(); return true
            default: return false
            }
        }
    }
}
