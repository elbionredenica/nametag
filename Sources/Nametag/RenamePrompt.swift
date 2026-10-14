import AppKit

enum RenamePrompt {
    enum Result {
        case save(String)
        case reset
        case cancel
    }

    static func run(for space: Space, current: String?) -> Result {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Name \(space.defaultTitle)"
        alert.informativeText = "Shown in Mission Control and the menu bar."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if current != nil { alert.addButton(withTitle: "Reset to \(space.defaultTitle)") }

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = current ?? ""
        field.placeholderString = space.defaultTitle
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save(field.stringValue)
        case .alertThirdButtonReturn: return .reset
        default: return .cancel
        }
    }
}
