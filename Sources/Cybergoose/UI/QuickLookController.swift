import AppKit
import Quartz

@MainActor
final class QuickLookController {
    private var panel: PreviewPanel?
    func show(_ url: URL) {
        if let panel, panel.representedURL == url, panel.isVisible { panel.close(); return }
        let panel = panel ?? PreviewPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.title = url.lastPathComponent; panel.representedURL = url
        let preview = QLPreviewView(frame: panel.contentView!.bounds, style: .normal)!
        preview.autoresizingMask = [.width, .height]
        preview.previewItem = url as NSURL
        panel.contentView = preview
        if self.panel == nil { panel.center() }
        self.panel = panel; panel.makeKeyAndOrderFront(nil)
    }
}

private final class PreviewPanel: NSPanel {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 53 { close() } else { super.keyDown(with: event) }
    }
}
