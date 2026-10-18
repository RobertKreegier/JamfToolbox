import Foundation

/// A change to how one device is scoped by a configuration profile.
public enum ScopeChange: String, CaseIterable {
    /// Add the device to the profile's excluded devices.
    case exclude
    /// Remove the device, and its assigned user, from the profile's direct targets.
    case removeTarget
    /// Remove the device, and its assigned user, from the profile's exclusions.
    case removeExclusion

    public var title: String {
        switch self {
        case .exclude: return "Exclude"
        case .removeTarget: return "Remove Target"
        case .removeExclusion: return "Remove Exclusion"
        }
    }
}

/// How one device is directly scoped by a profile: the parts the actions can
/// change. Group targets and exclusions are never edited.
public struct DirectScope: Codable, Hashable {
    public var targetedDirectly = false
    public var targetedByUser = false
    public var excludedDirectly = false
    public var excludedByUser = false

    public func allows(_ change: ScopeChange) -> Bool {
        switch change {
        case .exclude: return !excludedDirectly
        case .removeTarget: return targetedDirectly || targetedByUser
        case .removeExclusion: return excludedDirectly || excludedByUser
        }
    }

    public init(targetedDirectly: Bool = false, targetedByUser: Bool = false, excludedDirectly: Bool = false, excludedByUser: Bool = false) {
        self.targetedDirectly = targetedDirectly
        self.targetedByUser = targetedByUser
        self.excludedDirectly = excludedDirectly
        self.excludedByUser = excludedByUser
    }
}

/// Edits a profile's scope XML. Only the device's own entries (and its
/// assigned user's) are touched; every other target, exclusion and limitation
/// is sent back exactly as Jamf Pro returned it.
public enum ProfileScopeEditor {
    public struct Edit {
        /// The request body: the profile's root element holding only `<scope>`.
        public let body: Data
        /// What changed, e.g. "removed the device from Targets".
        public let changes: [String]
        /// The scope that should read back after the change.
        public let expected: [String: Set<String>]

        public init(body: Data, changes: [String], expected: [String: Set<String>]) {
            self.body = body
            self.changes = changes
            self.expected = expected
        }
    }

    public static func deviceElement(_ kind: GroupKind) -> String { kind == .computer ? "computer" : "mobile_device" }

    /// Applies `change` to `xml` (a GET of the profile's Scope subset). The
    /// Edit has no changes when the device is already in the requested state.
    public static func apply(_ change: ScopeChange, to xml: Data, kind: GroupKind,
                      deviceID: String, username: String) throws -> Edit {
        guard let root = ScopeXML.parse(xml), let scope = root.first("scope") else {
            throw ServiceError("Jamf Pro returned a profile without a scope, so nothing was changed.")
        }
        let user = username.trimmingCharacters(in: .whitespaces)
        var changes: [String] = []

        switch change {
        case .exclude:
            let devices = scope.child("exclusions", create: true)!.child(kind.membersKey, create: true)!
            if !devices.all(deviceElement(kind)).contains(where: { $0.text("id") == deviceID }) {
                let entry = ScopeXML(name: deviceElement(kind))
                entry.children.append(ScopeXML(name: "id", value: deviceID))
                devices.children.append(entry)
                devices.updateSize()
                changes.append("added the device to Exclusions")
            }
        case .removeTarget, .removeExclusion:
            let section = change == .removeTarget ? scope : scope.child("exclusions", create: false)
            let where_ = change == .removeTarget ? "Targets" : "Exclusions"
            if let section {
                if section.child(kind.membersKey, create: false)?.remove(where: { $0.text("id") == deviceID }) ?? 0 > 0 {
                    changes.append("removed the device from \(where_)")
                }
                if !user.isEmpty,
                   section.child("jss_users", create: false)?
                    .remove(where: { $0.text("name").caseInsensitiveCompare(user) == .orderedSame }) ?? 0 > 0 {
                    changes.append("removed user “\(user)” from \(where_)")
                }
            }
        }

        let out = ScopeXML(name: root.name)
        out.children = [scope]
        let body = #"<?xml version="1.0" encoding="UTF-8"?>"# + out.serialized
        return Edit(body: Data(body.utf8), changes: changes, expected: fingerprint(of: scope))
    }

    /// Every list in a scope, as path → entry ids (or names when an entry has no id),
    /// plus single values such as `all_mobile_devices`. Used to check that a
    /// change read back as sent and touched nothing else.
    public static func fingerprint(of xml: Data) -> [String: Set<String>]? {
        guard let scope = ScopeXML.parse(xml)?.first("scope") else { return nil }
        return fingerprint(of: scope)
    }

    public static func fingerprint(of scope: ScopeXML) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        func walk(_ element: ScopeXML, _ path: String) {
            if element.children.isEmpty {
                let value = element.value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { result[path, default: []].insert(value) }
                return
            }
            for child in element.children {
                if !child.children.isEmpty, child.children.contains(where: { $0.name == "id" || $0.name == "name" }) {
                    // A list entry: identify it by id, else name.
                    let id = child.text("id"), name = child.text("name")
                    let key = !id.isEmpty && id != "-1" ? "id:\(id)" : "name:\(name.lowercased())"
                    result[path, default: []].insert(key)
                } else if child.name != "size" {
                    walk(child, path + "/" + child.name)
                }
            }
        }
        walk(scope, "scope")
        return result.filter { !$0.value.isEmpty }
    }

    /// Paths whose entries differ between two fingerprints.
    public static func differences(_ a: [String: Set<String>], _ b: [String: Set<String>]) -> [String] {
        Set(a.keys).union(b.keys).filter { a[$0] ?? [] != b[$0] ?? [] }.sorted()
    }
}

/// A minimal XML element tree for Jamf Pro's Classic API scope documents,
/// which hold only elements and text. Built with `XMLParser`, so it works on
/// iOS too (`XMLDocument` is macOS-only). Whitespace between elements is
/// dropped; text inside an element is kept as is.
public final class ScopeXML {
    public let name: String
    public var attributes: [(String, String)] = []
    public var children: [ScopeXML] = []
    /// The text of an element with no child elements.
    public var value = ""

    public init(name: String, value: String = "") {
        self.name = name
        self.value = value
    }

    public static func parse(_ data: Data) -> ScopeXML? {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        guard parser.parse() else { return nil }
        return builder.root
    }

    public func first(_ name: String) -> ScopeXML? { children.first { $0.name == name } }
    public func all(_ name: String) -> [ScopeXML] { children.filter { $0.name == name } }

    /// The trimmed text of the first child named `name` ("" if none).
    public func text(_ name: String) -> String { (first(name)?.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    public func child(_ name: String, create: Bool) -> ScopeXML? {
        if let found = first(name) { return found }
        guard create else { return nil }
        let made = ScopeXML(name: name)
        children.append(made)
        return made
    }

    /// Removes matching entries from a list and fixes its `<size>`, if any.
    public func remove(where matches: (ScopeXML) -> Bool) -> Int {
        let before = children.count
        children.removeAll { $0.name != "size" && matches($0) }
        let removed = before - children.count
        if removed > 0 { updateSize() }
        return removed
    }

    public func updateSize() {
        first("size")?.value = String(children.filter { $0.name != "size" }.count)
    }

    public var serialized: String {
        let attrs = attributes.map { " \($0.0)=\"\(Self.escape($0.1, quotes: true))\"" }.joined()
        let inner = children.isEmpty ? Self.escape(value, quotes: false) : children.map(\.serialized).joined()
        return "<\(name)\(attrs)>\(inner)</\(name)>"
    }

    private static func escape(_ text: String, quotes: Bool) -> String {
        var out = text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        if quotes { out = out.replacingOccurrences(of: "\"", with: "&quot;") }
        return out
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: ScopeXML?
        private var stack: [ScopeXML] = []
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let element = ScopeXML(name: elementName)
            element.attributes = attributeDict.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
            if let parent = stack.last { parent.children.append(element) } else { root = element }
            stack.append(element)
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { text += String(decoding: CDATABlock, as: UTF8.self) }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            guard let element = stack.popLast() else { return }
            if element.children.isEmpty { element.value = text }
            text = ""
        }
    }
}
