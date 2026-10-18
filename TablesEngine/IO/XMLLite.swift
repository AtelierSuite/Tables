import Foundation

/// A tiny XML tree, built on `XMLParser`. Namespace prefixes are
/// dropped so `<x:sheetData>` and `<sheetData>` look the same to callers.
///
/// The qualified spellings are kept alongside the stripped ones so a subtree
/// can be written back out exactly as it came in — a part of the file we do
/// not model is only safe to re-emit if its prefixes survive the trip.
public final class XMLElement {
    public let name: String
    /// The name as the file spelled it, prefix and all.
    public let qualifiedName: String
    public private(set) var attributes: [String: String]
    /// Attributes keyed by their qualified names, including `xmlns` declarations.
    public private(set) var qualifiedAttributes: [String: String]
    public private(set) var children: [XMLElement] = []
    public private(set) var text: String = ""
    public weak var parent: XMLElement?

    public convenience init(name: String, attributes: [String: String]) {
        self.init(name: name, qualifiedName: name, attributes: attributes, qualifiedAttributes: attributes)
    }

    public init(
        name: String, qualifiedName: String,
        attributes: [String: String], qualifiedAttributes: [String: String]
    ) {
        self.name = name
        self.qualifiedName = qualifiedName
        self.attributes = attributes
        self.qualifiedAttributes = qualifiedAttributes
    }

    public func attribute(_ key: String) -> String? { attributes[key] }

    public func children(named name: String) -> [XMLElement] { children.filter { $0.name == name } }

    public func firstChild(named name: String) -> XMLElement? { children.first { $0.name == name } }

    /// Follows a slash-separated path of element names.
    public func firstDescendant(atPath path: String) -> XMLElement? {
        var current: XMLElement? = self
        for step in path.split(separator: "/") {
            current = current?.firstChild(named: String(step))
            if current == nil { return nil }
        }
        return current
    }

    fileprivate func appendChild(_ child: XMLElement) {
        child.parent = self
        children.append(child)
    }

    fileprivate func appendText(_ value: String) {
        text += value
    }

    // MARK: - Editing

    /// Sets or, with `nil`, removes an attribute by its local name — the
    /// spelling it already has in the file if it has one, unprefixed if not.
    public func setAttribute(_ name: String, _ value: String?) {
        let existing = qualifiedAttributes.keys.first { key in
            key == name || (key.hasSuffix(":" + name) && !key.hasPrefix("xmlns"))
        }
        let key = existing ?? name
        attributes[name] = value
        qualifiedAttributes[key] = value
    }

    /// Declares namespace bindings on this element itself, so it carries them
    /// wherever it is moved.
    public func declareNamespaces(_ bindings: [String: String]) {
        for (prefix, uri) in bindings {
            qualifiedAttributes[prefix.isEmpty ? "xmlns" : "xmlns:\(prefix)"] = uri
        }
    }

    public func insertChild(_ child: XMLElement, at index: Int) {
        child.parent = self
        children.insert(child, at: min(max(index, 0), children.count))
    }

    public func removeChild(_ child: XMLElement) {
        children.removeAll { $0 === child }
    }

    public func replaceChild(_ old: XMLElement, with new: XMLElement) {
        guard let index = children.firstIndex(where: { $0 === old }) else { return }
        new.parent = self
        children[index] = new
    }

    public func setText(_ value: String) {
        text = value
    }

    /// Puts `children` in this order, keeping only those already here.
    public func reorderChildren(_ ordered: [XMLElement]) {
        let kept = ordered.filter { candidate in children.contains { $0 === candidate } }
        let rest = children.filter { child in !kept.contains { $0 === child } }
        children = kept + rest
    }

    // MARK: - Namespaces

    /// The namespace bindings this element declares, keyed by prefix. The
    /// default namespace uses the empty string.
    public var namespaceDeclarations: [String: String] {
        var result: [String: String] = [:]
        for (key, value) in qualifiedAttributes {
            if key == "xmlns" {
                result[""] = value
            } else if key.hasPrefix("xmlns:") {
                result[String(key.dropFirst("xmlns:".count))] = value
            }
        }
        return result
    }

    /// Every namespace prefix this element itself uses, in its own name and in
    /// its attribute names. Unprefixed attributes carry no namespace at all, so
    /// they are not counted.
    public var usedNamespacePrefixes: Set<String> {
        var result: Set<String> = [Self.prefix(of: qualifiedName) ?? ""]
        for key in qualifiedAttributes.keys where key != "xmlns" && !key.hasPrefix("xmlns:") {
            if let prefix = Self.prefix(of: key) { result.insert(prefix) }
        }
        return result
    }

    /// Prefixes named in attribute *values* by markup compatibility:
    /// `mc:Ignorable="x14ac"`, `Requires="cx1"` on a choice. Nothing in the
    /// element's own name uses them, yet dropping their declarations changes
    /// what a reader makes of it — a choice whose requirement it cannot
    /// resolve is a choice it skips.
    public var compatibilityPrefixes: Set<String> {
        var result: Set<String> = []
        for (key, value) in qualifiedAttributes {
            let local = key.split(separator: ":").last.map(String.init) ?? key
            let named = (name == "Choice" && key == "Requires")
                || (key.contains(":") && Self.compatibilityAttributes.contains(local))
            guard named else { continue }
            for token in value.split(whereSeparator: \.isWhitespace) {
                // `ProcessContent` lists qualified names; the rest, prefixes.
                result.insert(String(token.split(separator: ":").first ?? token))
            }
        }
        return result
    }

    private static let compatibilityAttributes: Set<String> = [
        "Ignorable", "MustUnderstand", "ProcessContent", "PreserveElements", "PreserveAttributes",
    ]

    /// What `prefix` was bound to at this point in the source document.
    ///
    /// An unbound default namespace is "no namespace", which is a real answer;
    /// an unbound prefix is a document we cannot make sense of, hence `nil`.
    public func sourceNamespaceBinding(forPrefix prefix: String) -> String? {
        var element: XMLElement? = self
        while let current = element {
            if let binding = current.namespaceDeclarations[prefix] { return binding }
            element = current.parent
        }
        return prefix.isEmpty ? "" : nil
    }

    private static func prefix(of qualified: String) -> String? {
        guard let colon = qualified.firstIndex(of: ":") else { return nil }
        return String(qualified[qualified.startIndex..<colon])
    }
}

public enum XMLLite {
    public struct ParseError: LocalizedError, Sendable {
        public var message: String
        public var errorDescription: String? { message }
    }

    public static func parse(_ data: Data) throws -> XMLElement {
        let builder = TreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        parser.shouldProcessNamespaces = false
        guard parser.parse(), let root = builder.root else {
            throw ParseError(message: builder.failure ?? parser.parserError?.localizedDescription
                             ?? "The document’s XML is malformed.")
        }
        return root
    }

    private final class TreeBuilder: NSObject, XMLParserDelegate {
        var root: XMLElement?
        var failure: String?
        private var stack: [XMLElement] = []

        private func localName(_ qualified: String) -> String {
            guard let colon = qualified.lastIndex(of: ":") else { return qualified }
            return String(qualified[qualified.index(after: colon)...])
        }

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName: String?, attributes: [String: String]
        ) {
            var stripped: [String: String] = [:]
            stripped.reserveCapacity(attributes.count)
            for (key, value) in attributes { stripped[localName(key)] = value }

            let element = XMLElement(
                name: localName(elementName), qualifiedName: elementName,
                attributes: stripped, qualifiedAttributes: attributes
            )
            if let parent = stack.last {
                parent.appendChild(element)
            } else {
                root = element
            }
            stack.append(element)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.appendText(string)
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            stack.last?.appendText(String(decoding: CDATABlock, as: UTF8.self))
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String,
            namespaceURI: String?, qualifiedName: String?
        ) {
            stack.removeLast()
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) {
            failure = parseError.localizedDescription
        }
    }

    /// Parses a fragment that uses prefixes bound in `namespaces`, returning
    /// its root with those bindings declared on it so it can be grafted into
    /// another tree whatever that tree calls the same namespaces.
    public static func fragment(_ xml: String, namespaces: [String: String]) -> XMLElement? {
        let declarations = namespaces.sorted { $0.key < $1.key }
            .map { " xmlns:\($0.key)=\"\(escape($0.value))\"" }.joined()
        guard let wrapper = try? parse(Data("<fragment\(declarations)>\(xml)</fragment>".utf8)),
              let root = wrapper.children.first else { return nil }
        root.parent = nil
        root.declareNamespaces(namespaces)
        return root
    }

    /// Writes an element and its subtree back out as XML text.
    ///
    /// The result is self-contained: every prefix it uses is declared inside
    /// it, so the fragment can be dropped into any document without inheriting
    /// anything. `inheritedNamespaces` names the bindings the destination
    /// already has in scope, purely so redundant declarations can be skipped.
    ///
    /// Returns `nil` when the subtree carries mixed content — text alongside
    /// child elements — or uses a prefix the source never declared. The parser
    /// flattens an element's text into one string, so re-emitting mixed content
    /// would move it; a fragment we cannot reproduce faithfully is one we have
    /// no business writing back.
    public static func serialize(
        _ element: XMLElement, inheritedNamespaces: [String: String] = [:]
    ) -> String? {
        var output = ""
        guard append(element, to: &output, inScope: inheritedNamespaces) else { return nil }
        return output
    }

    private static func append(
        _ element: XMLElement, to output: inout String, inScope: [String: String]
    ) -> Bool {
        var scope = inScope
        var declarations: [String: String] = [:]

        // Declarations the source put on this element travel with it, so that a
        // binding a descendant relies on is not quietly re-pointed.
        for (prefix, uri) in element.namespaceDeclarations where scope[prefix] != uri {
            declarations[prefix] = uri
            scope[prefix] = uri
        }
        for prefix in element.usedNamespacePrefixes where prefix != "xml" {
            guard let uri = element.sourceNamespaceBinding(forPrefix: prefix) else { return false }
            guard scope[prefix] != uri else { continue }
            declarations[prefix] = uri
            scope[prefix] = uri
        }
        // Declared where the source declared them, if it did; a value naming
        // a prefix nobody bound was already meaningless and stays so.
        for prefix in element.compatibilityPrefixes where prefix != "xml" {
            guard let uri = element.sourceNamespaceBinding(forPrefix: prefix), !uri.isEmpty,
                  scope[prefix] != uri else { continue }
            declarations[prefix] = uri
            scope[prefix] = uri
        }

        var attributes: [(name: String, value: String)] = declarations
            .map { (name: $0.key.isEmpty ? "xmlns" : "xmlns:\($0.key)", value: $0.value) }
            .sorted { $0.name < $1.name }
        // Attribute order carries no meaning in XML, but a stable one keeps the
        // bytes we write reproducible.
        attributes += element.qualifiedAttributes
            .filter { $0.key != "xmlns" && !$0.key.hasPrefix("xmlns:") }
            .map { (name: $0.key, value: $0.value) }
            .sorted { $0.name < $1.name }

        output += "<" + element.qualifiedName
        for attribute in attributes {
            output += " \(attribute.name)=\"\(escape(attribute.value))\""
        }

        if element.children.isEmpty {
            if element.text.isEmpty {
                output += "/>"
                return true
            }
            output += ">" + escape(element.text) + "</" + element.qualifiedName + ">"
            return true
        }

        guard element.text.trimmed.isEmpty else { return false }
        output += ">"
        for child in element.children {
            guard append(child, to: &output, inScope: scope) else { return false }
        }
        output += "</" + element.qualifiedName + ">"
        return true
    }

    /// Escapes text for inclusion in XML content or a quoted attribute.
    public static func escape(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for character in value.unicodeScalars {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            case "\n": result += "&#10;"
            case "\r": result += "&#13;"
            case "\t": result += "&#9;"
            default:
                // Strip control characters XML 1.0 forbids.
                if character.value < 0x20 { continue }
                result.unicodeScalars.append(character)
            }
        }
        return result
    }
}
