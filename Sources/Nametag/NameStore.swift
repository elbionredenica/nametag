import Foundation

/// Desktop names and preferences, kept in UserDefaults.
///
/// Names for desktops that no longer exist are kept on purpose: when a display is unplugged its
/// desktops disappear from the list, and they should get their names back when it returns.
final class NameStore {
    static let didChange = Notification.Name("NametagNamesDidChange")

    private let defaults = UserDefaults.standard

    init() {
        defaults.register(defaults: ["enabled": true, "showNameInMenuBar": true])
    }

    func name(for space: Space) -> String? {
        names[space.key]
    }

    func setName(_ name: String?, for space: Space) {
        var all = names
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        all[space.key] = trimmed.isEmpty ? nil : trimmed
        defaults.set(all, forKey: "names")
        changed()
    }

    var enabled: Bool {
        get { defaults.bool(forKey: "enabled") }
        set { defaults.set(newValue, forKey: "enabled"); changed() }
    }

    var showNameInMenuBar: Bool {
        get { defaults.bool(forKey: "showNameInMenuBar") }
        set { defaults.set(newValue, forKey: "showNameInMenuBar"); changed() }
    }

    private var names: [String: String] {
        defaults.dictionary(forKey: "names") as? [String: String] ?? [:]
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
