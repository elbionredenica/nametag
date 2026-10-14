import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = NameStore()
    private var overlay: OverlayController!
    private var statusMenu: StatusMenu!
    private var hotkey: Hotkey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        overlay = OverlayController(store: store)
        statusMenu = StatusMenu(store: store) { [weak self] space in self?.rename(space) }

        // ⌃⌥N renames the desktop you're on.
        hotkey = Hotkey(keyCode: kVK_ANSI_N, modifiers: controlKey | optionKey) { [weak self] in
            if let space = Spaces.active { self?.rename(space) }
        }

        let refresh: (Notification) -> Void = { [weak self] _ in self?.statusMenu.refreshTitle() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: refresh)
        NotificationCenter.default.addObserver(forName: NameStore.didChange, object: nil, queue: .main, using: refresh)

        overlay.start()
        Permissions.onboardIfNeeded()
    }

    private func rename(_ space: Space) {
        switch RenamePrompt.run(for: space, current: store.name(for: space)) {
        case .save(let name): store.setName(name, for: space)
        case .reset: store.setName(nil, for: space)
        case .cancel: break
        }
    }
}
