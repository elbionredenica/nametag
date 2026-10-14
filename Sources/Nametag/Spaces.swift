import AppKit

// Private SkyLight calls (exported through CoreGraphics). Read-only, and they work with SIP on.
// They are the reason Nametag can't ship on the Mac App Store.
@_silgen_name("CGSMainConnectionID") private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopyManagedDisplaySpaces") private func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> CFArray
@_silgen_name("CGSGetActiveSpace") private func CGSGetActiveSpace(_ cid: Int32) -> UInt64

/// One desktop (or full-screen app space) as macOS tracks it.
struct Space: Equatable {
    /// Stable across reorders and restarts — names are stored under this.
    let key: String
    let managedID: UInt64
    /// CGS display identifier: a display UUID, or "Main" when Spaces span all displays.
    let displayIdentifier: String
    /// Position on its display, in the order Mission Control shows it.
    let index: Int
    /// The N in "Desktop N"; nil for full-screen app spaces.
    let number: Int?
    let isActive: Bool

    var defaultTitle: String { number.map { "Desktop \($0)" } ?? "Full-screen app" }
}

enum Spaces {
    static func all() -> [Space] {
        let cid = CGSMainConnectionID()
        let active = CGSGetActiveSpace(cid)
        let displays = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] ?? []
        var result: [Space] = []
        for display in displays {
            let identifier = display["Display Identifier"] as? String ?? "Main"
            var desktopNumber = 0
            for (index, info) in ((display["Spaces"] as? [[String: Any]]) ?? []).enumerated() {
                let managedID = (info["ManagedSpaceID"] as? NSNumber)?.uint64Value ?? 0
                let uuid = info["uuid"] as? String ?? ""
                let isDesktop = (info["type"] as? NSNumber)?.intValue == 0
                if isDesktop { desktopNumber += 1 }
                result.append(Space(
                    // Older macOS versions gave the first desktop an empty uuid.
                    key: uuid.isEmpty ? "managed-\(managedID)" : uuid,
                    managedID: managedID,
                    displayIdentifier: identifier,
                    index: index,
                    number: isDesktop ? desktopNumber : nil,
                    isActive: managedID == active
                ))
            }
        }
        return result
    }

    static var active: Space? { all().first { $0.isActive } }

    /// The spaces Mission Control shows on a given physical display.
    static func on(display: CGDirectDisplayID, in spaces: [Space]) -> [Space] {
        let identifiers = Set(spaces.map(\.displayIdentifier))
        if identifiers.count == 1 { return spaces }
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue(),
              let uuidString = CFUUIDCreateString(nil, uuid) as String? else { return [] }
        return spaces.filter { $0.displayIdentifier.caseInsensitiveCompare(uuidString) == .orderedSame }
    }
}
