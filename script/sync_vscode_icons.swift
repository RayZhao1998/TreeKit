#!/usr/bin/env swift

import Foundation

private struct IconDefinition: Decodable {
    let iconPath: String
}

private struct LightTheme: Decodable {
    let file: String
    let folder: String
    let folderExpanded: String
    let fileExtensions: [String: String]
    let fileNames: [String: String]?
    let folderNames: [String: String]?
    let folderNamesExpanded: [String: String]?
}

private struct IconTheme: Decodable {
    let iconDefinitions: [String: IconDefinition]
    let file: String
    let folder: String
    let folderExpanded: String
    let fileExtensions: [String: String]
    let fileNames: [String: String]?
    let folderNames: [String: String]?
    let folderNamesExpanded: [String: String]?
    let light: LightTheme
}

private let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(
        Data("usage: sync_vscode_icons.swift <vscode-icons checkout> <TreeKit checkout>\n".utf8)
    )
    exit(2)
}

private let fileManager = FileManager.default
private let upstream = URL(fileURLWithPath: arguments[1], isDirectory: true)
private let treeKit = URL(fileURLWithPath: arguments[2], isDirectory: true)
private let iconsDirectory = upstream.appendingPathComponent("icons", isDirectory: true)
private let resources = treeKit.appendingPathComponent("Sources/TreeKit/Resources", isDirectory: true)
private let catalog = resources.appendingPathComponent("FileTreeIcons.xcassets", isDirectory: true)
private let generatedSwift = treeKit.appendingPathComponent(
    "Sources/TreeKit/FileTreeBuiltInIcons.generated.swift"
)

private func decodeTheme(_ name: String) throws -> IconTheme {
    let url = iconsDirectory.appendingPathComponent("theme-\(name).json")
    return try JSONDecoder().decode(IconTheme.self, from: Data(contentsOf: url))
}

private let minimal = try decodeTheme("minimal")
private let standard = try decodeTheme("default")
private let complete = try decodeTheme("complete")

if fileManager.fileExists(atPath: catalog.path) {
    try fileManager.removeItem(at: catalog)
}
try fileManager.createDirectory(at: catalog, withIntermediateDirectories: true)
try Data("""
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
""".utf8).write(to: catalog.appendingPathComponent("Contents.json"))

private func contentsJSON(template: Bool) -> Data {
    Data("""
{
  "images" : [
    {
      "filename" : "light.svg",
      "idiom" : "universal"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "dark"
        }
      ],
      "filename" : "dark.svg",
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "preserves-vector-representation" : true,
    "template-rendering-intent" : "\(template ? "template" : "original")"
  }
}
""".utf8)
}

private func copyImageSet(
    name: String,
    darkSource: URL,
    lightSource: URL,
    template: Bool
) throws {
    let imageSet = catalog.appendingPathComponent("\(name).imageset", isDirectory: true)
    try fileManager.createDirectory(at: imageSet, withIntermediateDirectories: true)
    try fileManager.copyItem(at: darkSource, to: imageSet.appendingPathComponent("dark.svg"))
    try fileManager.copyItem(at: lightSource, to: imageSet.appendingPathComponent("light.svg"))
    try contentsJSON(template: template).write(to: imageSet.appendingPathComponent("Contents.json"))
}

private let iconNames = complete.iconDefinitions.keys
    .filter { !$0.hasSuffix("_light") }
    .sorted()

for iconName in iconNames {
    try copyImageSet(
        name: "TreeKitIcon-\(iconName)",
        darkSource: iconsDirectory.appendingPathComponent("\(iconName).svg"),
        lightSource: iconsDirectory.appendingPathComponent("\(iconName)-light.svg"),
        template: true
    )

    guard
        let darkPath = complete.iconDefinitions[iconName]?.iconPath,
        let lightPath = complete.iconDefinitions["\(iconName)_light"]?.iconPath
    else {
        fatalError("Missing complete icon definition for \(iconName)")
    }
    try copyImageSet(
        name: "TreeKitIcon-\(iconName)-colored",
        darkSource: iconsDirectory.appendingPathComponent(darkPath.replacingOccurrences(of: "./", with: "")),
        lightSource: iconsDirectory.appendingPathComponent(lightPath.replacingOccurrences(of: "./", with: "")),
        template: false
    )
}

private func swiftString(_ value: String) -> String {
    String(reflecting: value)
}

private func dictionarySource(_ dictionary: [String: String]?) -> String {
    let entries = (dictionary ?? [:]).map { key, value in
        (key.lowercased(), value)
    }.sorted { left, right in
        if left.0 != right.0 { return left.0 < right.0 }
        return left.1 < right.1
    }
    guard !entries.isEmpty else { return "[:]" }
    return "[\n" + entries.map { key, value in
        "            \(swiftString(key)): \(swiftString(value))"
    }.joined(separator: ",\n") + "\n        ]"
}

private func themeSource(_ theme: IconTheme) -> String {
    """
    FileTreeBuiltInIconTheme(
        file: \(swiftString(theme.file)),
        folder: \(swiftString(theme.folder)),
        expandedFolder: \(swiftString(theme.folderExpanded)),
        fileNames: \(dictionarySource(theme.fileNames)),
        fileExtensions: \(dictionarySource(theme.fileExtensions)),
        folderNames: \(dictionarySource(theme.folderNames)),
        expandedFolderNames: \(dictionarySource(theme.folderNamesExpanded))
    )
    """
}

private let availableNames = "[\n" + iconNames.map {
    "        \(swiftString($0))"
}.joined(separator: ",\n") + "\n    ]"

private let source = """
// Generated by script/sync_vscode_icons.swift from pierrecomputer/vscode-icons 0.0.9.
// Do not edit manually.

internal enum FileTreeBuiltInIconCatalog {
    static let minimal = \(themeSource(minimal))

    static let standard = \(themeSource(standard))

    static let complete = \(themeSource(complete))

    static let availableNames: Set<String> = \(availableNames)

    static func theme(for set: FileTreeBuiltInIconSet) -> FileTreeBuiltInIconTheme {
        switch set {
        case .minimal, .none:
            minimal
        case .standard:
            standard
        case .complete:
            complete
        }
    }
}
"""
try Data(source.utf8).write(to: generatedSwift)

private let thirdPartyDirectory = resources.appendingPathComponent("ThirdParty", isDirectory: true)
try fileManager.createDirectory(at: thirdPartyDirectory, withIntermediateDirectories: true)
let licenseSource = upstream.appendingPathComponent("LICENSE.md")
let licenseDestination = thirdPartyDirectory.appendingPathComponent("pierre-vscode-icons-LICENSE.md")
if fileManager.fileExists(atPath: licenseDestination.path) {
    try fileManager.removeItem(at: licenseDestination)
}
try fileManager.copyItem(at: licenseSource, to: licenseDestination)

print("Imported \(iconNames.count) icon definitions into \(catalog.path)")
