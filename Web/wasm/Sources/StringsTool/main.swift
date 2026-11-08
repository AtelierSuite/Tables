import Foundation

// Converts the Apple apps' string catalogues into one flat JSON table per
// language for the web app, so both say the same things in the same languages.
//
//   strings-tool <output folder> <name>=<catalogue.xcstrings>[,<catalogue>...] ...
//
// Each name becomes <output>/<name>-<language>.json. A string without a
// translation falls back to the catalogue's source language, then to its key.

struct Catalogue {
    let sourceLanguage: String
    let strings: [String: [String: Any]]

    init(contentsOf url: URL) throws {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
        sourceLanguage = json["sourceLanguage"] as? String ?? "en"
        strings = json["strings"] as? [String: [String: Any]] ?? [:]
    }

    var languages: Set<String> {
        var result: Set<String> = [sourceLanguage]
        for entry in strings.values {
            for language in (entry["localizations"] as? [String: Any] ?? [:]).keys { result.insert(language) }
        }
        return result
    }

    /// The value of one localisation: its string unit, or for a plural, the "other" form.
    static func value(of localization: Any?) -> String? {
        guard let localization = localization as? [String: Any] else { return nil }
        if let unit = localization["stringUnit"] as? [String: Any], let value = unit["value"] as? String { return value }
        if let variations = localization["variations"] as? [String: Any] {
            for kind in ["plural", "device"] {
                if let forms = variations[kind] as? [String: Any] {
                    for form in ["other", "one", "mac", "iphone"] where forms[form] != nil {
                        if let value = value(of: forms[form]) { return value }
                    }
                }
            }
        }
        return nil
    }

    func table(for language: String) -> [String: String] {
        var table: [String: String] = [:]
        for (key, entry) in strings {
            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            table[key] = Self.value(of: localizations[language]) ?? Self.value(of: localizations[sourceLanguage]) ?? key
        }
        return table
    }
}

let arguments = CommandLine.arguments.dropFirst()
guard let output = arguments.first, arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: strings-tool <output folder> <name>=<catalogue>[,<catalogue>] ...\n".utf8))
    exit(2)
}
let outputFolder = URL(fileURLWithPath: output, isDirectory: true)
try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)

var languages: Set<String> = []
for group in arguments.dropFirst() {
    let parts = group.split(separator: "=", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { continue }
    let catalogues = try parts[1].split(separator: ",").map { try Catalogue(contentsOf: URL(fileURLWithPath: String($0))) }
    let groupLanguages = catalogues.reduce(into: Set<String>()) { $0.formUnion($1.languages) }
    languages.formUnion(groupLanguages)
    for language in groupLanguages.sorted() {
        var table: [String: String] = [:]
        for catalogue in catalogues {
            table.merge(catalogue.table(for: language)) { first, _ in first }
        }
        let data = try JSONSerialization.data(withJSONObject: table, options: [.sortedKeys])
        try data.write(to: outputFolder.appendingPathComponent("\(parts[0])-\(language).json"))
    }
}
let index = try JSONSerialization.data(withJSONObject: ["languages": languages.sorted()], options: [.sortedKeys])
try index.write(to: outputFolder.appendingPathComponent("languages.json"))
print("Wrote strings for \(languages.sorted().joined(separator: ", ")) to \(outputFolder.path)")
