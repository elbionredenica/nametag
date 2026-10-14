import AppKit
import ServiceManagement

/// The menu-bar item: shows the current desktop's name and hosts all of Nametag's controls.
final class StatusMenu: NSObject, NSMenuDelegate {
    private let store: NameStore
    private let rename: (Space) -> Void
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    init(store: NameStore, rename: @escaping (Space) -> Void) {
        self.store = store
        self.rename = rename
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refreshTitle()
    }

    func refreshTitle() {
        guard let button = item.button else { return }
        button.image = TagIcon.image(filled: store.enabled)
        if store.enabled, store.showNameInMenuBar, let space = Spaces.active, let name = store.name(for: space) {
            button.title = " " + name
            button.imagePosition = .imageLeading
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if !Permissions.trusted {
            menu.addItem(action("Allow Accessibility Access…", #selector(openPermissions)))
            menu.addItem(.separator())
        }

        let toggle = action("Show Names in Mission Control", #selector(toggleEnabled))
        toggle.state = store.enabled ? .on : .off
        menu.addItem(toggle)
        menu.addItem(.separator())

        let desktops = Spaces.all().filter { $0.number != nil }
        let displays = Array(NSOrderedSet(array: desktops.map(\.displayIdentifier))) as? [String] ?? []
        for (d, display) in displays.enumerated() {
            if displays.count > 1 { menu.addItem(header("Display \(d + 1)")) }
            for space in desktops where space.displayIdentifier == display {
                let entry = action("", #selector(renameSpace(_:)))
                entry.attributedTitle = title(for: space)
                entry.representedObject = space.key
                entry.state = space.isActive ? .on : .off
                entry.toolTip = "Click to rename"
                menu.addItem(entry)
            }
        }

        menu.addItem(.separator())
        let renameCurrent = action("Rename Current Desktop…", #selector(renameActive))
        renameCurrent.keyEquivalent = "n"
        renameCurrent.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(renameCurrent)

        let showName = action("Show Name in Menu Bar", #selector(toggleShowName))
        showName.state = store.showNameInMenuBar ? .on : .off
        menu.addItem(showName)

        let login = action("Launch at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Nametag", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    // MARK: Actions

    @objc private func toggleEnabled() { store.enabled.toggle() }
    @objc private func toggleShowName() { store.showNameInMenuBar.toggle() }
    @objc private func openPermissions() { Permissions.request() }

    @objc private func renameActive() {
        if let space = Spaces.active { rename(space) }
    }

    @objc private func renameSpace(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String,
              let space = Spaces.all().first(where: { $0.key == key }) else { return }
        rename(space)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nMove Nametag to your Applications folder and try again."
            alert.runModal()
        }
    }

    // MARK: Helpers

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func title(for space: Space) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        guard let name = store.name(for: space) else {
            return NSAttributedString(string: space.defaultTitle, attributes: [.font: font])
        }
        let title = NSMutableAttributedString(string: name, attributes: [.font: font])
        title.append(NSAttributedString(string: "   \(space.defaultTitle)", attributes: [
            .font: font, .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return title
    }
}
