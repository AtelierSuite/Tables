import Foundation

/// Reads `docProps/core.xml` and `docProps/app.xml`, and writes the changes a
/// person made to them back into the package a save carries through.
///
/// The parts themselves stay where package preservation keeps them. A save
/// patches only the core properties that differ from the part as read, so
/// everything else in it is written back untouched; a workbook without them
/// is given both parts afresh.
public enum DocumentPropertiesParts {
    public static let corePropertiesRelationshipType =
        "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties"
    public static let extendedPropertiesRelationshipType =
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties"
    public static let corePropertiesContentType = "application/vnd.openxmlformats-package.core-properties+xml"
    public static let extendedPropertiesContentType =
        "application/vnd.openxmlformats-officedocument.extended-properties+xml"

    static let corePath = "docProps/core.xml"
    static let appPath = "docProps/app.xml"

    private static let namespaces = [
        "cp": "http://schemas.openxmlformats.org/package/2006/metadata/core-properties",
        "dc": "http://purl.org/dc/elements/1.1/",
        "dcterms": "http://purl.org/dc/terms/",
        "xsi": "http://www.w3.org/2001/XMLSchema-instance",
    ]

    /// The text properties, by the element that holds each, in the order the
    /// schema lists them, which is the order new ones are written in.
    private static var textProperties: [(prefix: String, name: String, keyPath: WritableKeyPath<DocumentProperties, String>)] { [
        ("cp", "category", \.category),
        ("dc", "creator", \.author),
        ("dc", "description", \.comments),
        ("cp", "keywords", \.keywords),
        ("cp", "lastModifiedBy", \.lastModifiedBy),
        ("dc", "subject", \.subject),
        ("dc", "title", \.title),
    ] }

    private static var dateProperties: [(name: String, keyPath: WritableKeyPath<DocumentProperties, Date?>)] { [
        ("created", \.created),
        ("modified", \.modified),
    ] }

    // MARK: - Reading

    /// The properties of the parts a save will carry through.
    public static func read(from package: PreservedPackage) -> DocumentProperties {
        var properties = DocumentProperties()
        if let path = corePropertiesPath(in: package), let data = package.parts[path],
           let root = try? XMLLite.parse(data) {
            properties = coreProperties(root)
        }
        if let path = path(ofType: extendedPropertiesRelationshipType, in: package), let data = package.parts[path],
           let root = try? XMLLite.parse(data) {
            properties.application = root.firstChild(named: "Application")?.text.trimmed ?? ""
            properties.company = root.firstChild(named: "Company")?.text ?? ""
        }
        return properties
    }

    private static func coreProperties(_ root: XMLElement) -> DocumentProperties {
        var properties = DocumentProperties()
        for property in textProperties {
            properties[keyPath: property.keyPath] = text(of: root.firstChild(named: property.name))
        }
        for property in dateProperties {
            properties[keyPath: property.keyPath] = root.firstChild(named: property.name).flatMap { date($0.text) }
        }
        return properties
    }

    /// An element's text, including the text of a `<cp:keywords>` written as
    /// a list of `<cp:value>` children.
    private static func text(of element: XMLElement?) -> String {
        guard let element else { return "" }
        guard !element.children.isEmpty else { return element.text }
        return element.children.map(\.text).joined(separator: " ")
    }

    // MARK: - Writing

    /// The package a save writes: `package` with `properties` written into
    /// its core properties part, or with both property parts added when it
    /// has neither.
    public static func package(_ package: PreservedPackage, writing properties: DocumentProperties) -> PreservedPackage {
        var package = package
        guard let path = corePropertiesPath(in: package), let data = package.parts[path] else {
            add(properties, to: &package)
            return package
        }
        if let patched = patched(data, with: properties) { package.parts[path] = patched }
        return package
    }

    /// The core properties part with whatever differs from `properties`
    /// changed, or `nil` when nothing does or the part can't be read.
    private static func patched(_ data: Data, with properties: DocumentProperties) -> Data? {
        guard let root = try? XMLLite.parse(data) else { return nil }
        let found = coreProperties(root)
        var changed = false
        for property in textProperties where found[keyPath: property.keyPath] != properties[keyPath: property.keyPath] {
            let value = properties[keyPath: property.keyPath]
            set(property.name, prefix: property.prefix, to: value.isEmpty ? nil : value, in: root)
            changed = true
        }
        for property in dateProperties {
            let value = properties[keyPath: property.keyPath]
            // Compared as written: the file keeps whole seconds.
            guard value.map(format) != found[keyPath: property.keyPath].map(format) else { continue }
            set(property.name, prefix: "dcterms", to: value.map(format), in: root, isDate: true)
            changed = true
        }
        guard changed, let xml = XMLLite.serialize(root) else { return nil }
        return Data(("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" + xml).utf8)
    }

    /// Replaces, adds or, with `nil`, removes one property element.
    private static func set(_ name: String, prefix: String, to value: String?, in root: XMLElement, isDate: Bool = false) {
        let existing = root.firstChild(named: name)
        guard let value else {
            if let existing { root.removeChild(existing) }
            return
        }
        if let existing, existing.children.isEmpty {
            existing.setText(value)
            return
        }
        let type = isDate ? " xsi:type=\"dcterms:W3CDTF\"" : ""
        let bindings = isDate ? ["dcterms": namespaces["dcterms"]!, "xsi": namespaces["xsi"]!]
            : [prefix: namespaces[prefix]!]
        guard let element = XMLLite.fragment(
            "<\(prefix):\(name)\(type)>\(XMLLite.escape(value))</\(prefix):\(name)>",
            namespaces: bindings) else { return }
        if let existing {
            root.replaceChild(existing, with: element)
        } else {
            root.insertChild(element, at: root.children.count)
        }
    }

    /// Adds core and extended properties parts, with their content types and
    /// the package relationships that find them.
    private static func add(_ properties: DocumentProperties, to package: inout PreservedPackage) {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<cp:coreProperties"
        for (prefix, uri) in namespaces.sorted(by: { $0.key < $1.key }) {
            xml += " xmlns:\(prefix)=\"\(uri)\""
        }
        xml += ">"
        for property in textProperties where !properties[keyPath: property.keyPath].isEmpty {
            let name = "\(property.prefix):\(property.name)"
            xml += "<\(name)>\(XMLLite.escape(properties[keyPath: property.keyPath]))</\(name)>"
        }
        for property in dateProperties {
            guard let date = properties[keyPath: property.keyPath] else { continue }
            xml += "<dcterms:\(property.name) xsi:type=\"dcterms:W3CDTF\">\(format(date))</dcterms:\(property.name)>"
        }
        xml += "</cp:coreProperties>"
        package.parts[corePath] = Data(xml.utf8)
        package.contentTypeOverrides["/" + corePath] = corePropertiesContentType
        package.rootRelationships.append(.init(type: corePropertiesRelationshipType, target: corePath))

        // Kept to what stays true of the workbook as it changes: sheet names
        // and counts would be stale after the next edit made elsewhere.
        guard path(ofType: extendedPropertiesRelationshipType, in: package) == nil else { return }
        let app = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
            + "<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\" "
            + "xmlns:vt=\"http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes\">"
            + "<Application>Tables</Application><DocSecurity>0</DocSecurity><ScaleCrop>false</ScaleCrop>"
            + "<LinksUpToDate>false</LinksUpToDate><SharedDoc>false</SharedDoc>"
            + "<HyperlinksChanged>false</HyperlinksChanged></Properties>"
        package.parts[appPath] = Data(app.utf8)
        package.contentTypeOverrides["/" + appPath] = extendedPropertiesContentType
        package.rootRelationships.append(.init(type: extendedPropertiesRelationshipType, target: appPath))
    }

    // MARK: - Package

    /// Whether a package path is one of the property parts Tables reads.
    public static func isModelled(_ path: String) -> Bool { path == corePath || path == appPath }

    /// Where the package keeps its core properties, if it kept any.
    public static func corePropertiesPath(in package: PreservedPackage) -> String? {
        path(ofType: corePropertiesRelationshipType, in: package)
    }

    /// The kept part a package relationship of `type` names. Transitional
    /// files spell the core properties type under another namespace, so the
    /// type is matched on its last segments.
    private static func path(ofType type: String, in package: PreservedPackage) -> String? {
        let suffix = type.split(separator: "/").suffix(2).joined(separator: "/")
        return package.rootRelationships.lazy
            .filter { $0.targetMode != "External" && $0.type.hasSuffix("/" + suffix) }
            .map { XLSXReader.PackagePreservation.absolutePath($0.target, relativeTo: "") }
            .first { package.parts[$0] != nil }
    }

    // MARK: - Dates

    private static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func date(_ text: String) -> Date? {
        let text = text.trimmed
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        // W3CDTF allows a bare date.
        formatter.formatOptions = [.withFullDate]
        return formatter.date(from: text)
    }
}
