import Foundation

/// A change to how one device is scoped by a configuration profile.
enum ScopeChange: String, CaseIterable {
    /// Add the device to the profile's excluded devices.
    case exclude
    /// Remove the device, and its assigned user, from the profile's direct targets.
    case removeTarget
    /// Remove the device, and its assigned user, from the profile's exclusions.
    case removeExclusion

    var title: String {
        switch self {
        case .exclude: return "Exclude"
        case .removeTarget: return "Remove Target"
        case .removeExclusion: return "Remove Exclusion"
        }
    }
}

/// How one device is directly scoped by a profile: the parts the actions can
/// change. Group targets and exclusions are never edited.
struct DirectScope: Codable, Hashable {
    var targetedDirectly = false
    var targetedByUser = false
    var excludedDirectly = false
    var excludedByUser = false

    func allows(_ change: ScopeChange) -> Bool {
        switch change {
        case .exclude: return !excludedDirectly
        case .removeTarget: return targetedDirectly || targetedByUser
        case .removeExclusion: return excludedDirectly || excludedByUser
        }
    }
}

/// Edits a profile's scope XML. Only the device's own entries (and its
/// assigned user's) are touched; every other target, exclusion and limitation
/// is sent back exactly as Jamf Pro returned it.
enum ProfileScopeEditor {
    struct Edit {
        /// The request body: the profile's root element holding only `<scope>`.
        let body: Data
        /// What changed, e.g. "removed the device from Targets".
        let changes: [String]
        /// The scope that should read back after the change.
        let expected: [String: Set<String>]
    }

    static func deviceElement(_ kind: GroupKind) -> String { kind == .computer ? "computer" : "mobile_device" }

    /// Applies `change` to `xml` (a GET of the profile's Scope subset). The
    /// Edit has no changes when the device is already in the requested state.
    static func apply(_ change: ScopeChange, to xml: Data, kind: GroupKind,
                      deviceID: String, username: String) throws -> Edit {
        let document = try XMLDocument(data: xml, options: [])
        guard let root = document.rootElement(),
              let scope = root.elements(forName: "scope").first else {
            throw ServiceError("Jamf Pro returned a profile without a scope, so nothing was changed.")
        }
        let user = username.trimmingCharacters(in: .whitespaces)
        var changes: [String] = []

        switch change {
        case .exclude:
            let exclusions = child(scope, "exclusions", create: true)!
            let devices = child(exclusions, kind.membersKey, create: true)!
            if !devices.elements(forName: deviceElement(kind)).contains(where: { text($0, "id") == deviceID }) {
                let entry = XMLElement(name: deviceElement(kind))
                entry.addChild(XMLElement(name: "id", stringValue: deviceID))
                devices.addChild(entry)
                updateSize(devices)
                changes.append("added the device to Exclusions")
            }
        case .removeTarget, .removeExclusion:
            let section = change == .removeTarget ? scope : child(scope, "exclusions", create: false)
            let where_ = change == .removeTarget ? "Targets" : "Exclusions"
            if let section {
                if remove(from: child(section, kind.membersKey, create: false), where: { text($0, "id") == deviceID }) > 0 {
                    changes.append("removed the device from \(where_)")
                }
                if !user.isEmpty,
                   remove(from: child(section, "jss_users", create: false),
                          where: { text($0, "name").caseInsensitiveCompare(user) == .orderedSame }) > 0 {
                    changes.append("removed user “\(user)” from \(where_)")
                }
            }
        }

        let out = XMLElement(name: root.name ?? "configuration_profile")
        out.addChild(scope.copy() as! XMLElement)
        let body = XMLDocument(rootElement: out)
        body.characterEncoding = "UTF-8"
        body.version = "1.0"
        return Edit(body: body.xmlData(options: []), changes: changes, expected: fingerprint(of: scope))
    }

    /// Every list in a scope, as path → entry ids (or names when an entry has no id),
    /// plus single values such as `all_mobile_devices`. Used to check that a
    /// change read back as sent and touched nothing else.
    static func fingerprint(of xml: Data) -> [String: Set<String>]? {
        guard let document = try? XMLDocument(data: xml, options: []),
              let scope = document.rootElement()?.elements(forName: "scope").first else { return nil }
        return fingerprint(of: scope)
    }

    static func fingerprint(of scope: XMLElement) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        func walk(_ element: XMLElement, _ path: String) {
            let children = element.children?.compactMap { $0 as? XMLElement } ?? []
            if children.isEmpty {
                let value = (element.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { result[path, default: []].insert(value) }
                return
            }
            for child in children {
                let grandchildren = child.children?.compactMap { $0 as? XMLElement } ?? []
                if !grandchildren.isEmpty, grandchildren.contains(where: { $0.name == "id" || $0.name == "name" }) {
                    // A list entry: identify it by id, else name.
                    let id = text(child, "id"), name = text(child, "name")
                    let key = !id.isEmpty && id != "-1" ? "id:\(id)" : "name:\(name.lowercased())"
                    result[path, default: []].insert(key)
                } else if child.name != "size" {
                    walk(child, path + "/" + (child.name ?? ""))
                }
            }
        }
        walk(scope, "scope")
        return result.filter { !$0.value.isEmpty }
    }

    /// Paths whose entries differ between two fingerprints.
    static func differences(_ a: [String: Set<String>], _ b: [String: Set<String>]) -> [String] {
        Set(a.keys).union(b.keys).filter { a[$0] ?? [] != b[$0] ?? [] }.sorted()
    }

    // MARK: Helpers

    private static func child(_ element: XMLElement?, _ name: String, create: Bool) -> XMLElement? {
        guard let element else { return nil }
        if let found = element.elements(forName: name).first { return found }
        guard create else { return nil }
        let made = XMLElement(name: name)
        element.addChild(made)
        return made
    }

    private static func text(_ element: XMLElement, _ name: String) -> String {
        (element.elements(forName: name).first?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes matching entries from a list and fixes its `<size>`, if any.
    private static func remove(from list: XMLElement?, where matches: (XMLElement) -> Bool) -> Int {
        guard let list else { return 0 }
        var removed = 0
        for case let entry as XMLElement in list.children ?? [] where entry.name != "size" && matches(entry) {
            entry.detach()
            removed += 1
        }
        if removed > 0 { updateSize(list) }
        return removed
    }

    private static func updateSize(_ list: XMLElement) {
        guard let size = list.elements(forName: "size").first else { return }
        size.stringValue = String(list.children?.filter { ($0 as? XMLElement)?.name != "size" }.count ?? 0)
    }
}
