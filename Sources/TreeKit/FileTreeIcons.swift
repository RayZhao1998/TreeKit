import Foundation

/// The built-in icon coverage used by TreeKit's default file rows.
public enum FileTreeBuiltInIconSet: String, CaseIterable, Equatable, Sendable {
    /// Structural file and folder icons plus low-noise text and image recognition.
    case minimal
    /// Common languages and file formats using monochrome icons.
    case standard
    /// The broadest language, framework, and tooling coverage with semantic colors.
    case complete
    /// Disable built-in file-type mappings while retaining structural fallbacks.
    case none
}

/// Structural icon slots that can be replaced without rebuilding the file-type map.
public enum FileTreeIconSlot: Hashable, Sendable {
    case file
    case folder
    case expandedFolder
}

/// An icon supplied by TreeKit or by the application embedding it.
public enum FileTreeIcon: Equatable, Sendable {
    /// A raw icon name from TreeKit's vendored `pierrecomputer/vscode-icons` catalog.
    case builtIn(String)
    /// An SF Symbol available on the current platform.
    case systemSymbol(String)
    /// An image in the main bundle or in a bundle identified by `bundleIdentifier`.
    case namedAsset(name: String, bundleIdentifier: String?)

    public static func asset(
        _ name: String,
        bundleIdentifier: String? = nil
    ) -> FileTreeIcon {
        .namedAsset(name: name, bundleIdentifier: bundleIdentifier)
    }
}

/// File icon selection and targeted remapping shared by SwiftUI, AppKit, and UIKit.
///
/// Rules resolve from most to least specific: exact basename, basename substring,
/// longest extension suffix, the selected built-in set, and finally the structural
/// file fallback. Keys are matched case-insensitively.
public struct FileTreeIcons: Equatable, Sendable {
    public var set: FileTreeBuiltInIconSet
    public var colored: Bool
    public var remap: [FileTreeIconSlot: FileTreeIcon]
    public var byFileName: [String: FileTreeIcon] {
        didSet { byFileName = Self.normalized(byFileName) }
    }
    public var byFileNameContains: [String: FileTreeIcon] {
        didSet { byFileNameContains = Self.normalized(byFileNameContains) }
    }
    public var byFileExtension: [String: FileTreeIcon] {
        didSet { byFileExtension = Self.normalizedExtensions(byFileExtension) }
    }

    public init(
        set: FileTreeBuiltInIconSet = .complete,
        colored: Bool = true,
        remap: [FileTreeIconSlot: FileTreeIcon] = [:],
        byFileName: [String: FileTreeIcon] = [:],
        byFileNameContains: [String: FileTreeIcon] = [:],
        byFileExtension: [String: FileTreeIcon] = [:]
    ) {
        self.set = set
        self.colored = colored
        self.remap = remap
        self.byFileName = Self.normalized(byFileName)
        self.byFileNameContains = Self.normalized(byFileNameContains)
        self.byFileExtension = Self.normalizedExtensions(byFileExtension)
    }

    public static var minimal: FileTreeIcons { .init(set: .minimal) }
    public static var standard: FileTreeIcons { .init(set: .standard) }
    public static var complete: FileTreeIcons { .init(set: .complete) }
    public static var none: FileTreeIcons { .init(set: .none) }

    private static func normalized(
        _ entries: [String: FileTreeIcon]
    ) -> [String: FileTreeIcon] {
        entries.reduce(into: [:]) { result, entry in
            result[entry.key.lowercased()] = entry.value
        }
    }

    private static func normalizedExtensions(
        _ entries: [String: FileTreeIcon]
    ) -> [String: FileTreeIcon] {
        entries.reduce(into: [:]) { result, entry in
            let key = entry.key.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            result[key] = entry.value
        }
    }
}

internal struct FileTreeBuiltInIconTheme: Sendable {
    let file: String
    let folder: String
    let expandedFolder: String
    let fileNames: [String: String]
    let fileExtensions: [String: String]
    let folderNames: [String: String]
    let expandedFolderNames: [String: String]
}

internal struct ResolvedFileTreeIcon: Sendable {
    enum Source: Equatable, Sendable {
        case builtInAsset(String)
        case systemSymbol(String)
        case namedAsset(name: String, bundleIdentifier: String?)
    }

    let source: Source
    let isTemplate: Bool
}

internal extension FileTreeIcons {
    func resolve(_ node: FileTreePath, isExpanded: Bool) -> ResolvedFileTreeIcon {
        let slot: FileTreeIconSlot = if node.kind == .directory {
            isExpanded ? .expandedFolder : .folder
        } else {
            .file
        }
        if let replacement = remap[slot] {
            return resolveCustom(replacement)
        }

        let theme = FileTreeBuiltInIconCatalog.theme(for: set)
        if node.kind == .directory {
            let lowerName = node.name.lowercased()
            let mappedName = if isExpanded {
                theme.expandedFolderNames[lowerName]
            } else {
                theme.folderNames[lowerName]
            }
            return resolveBuiltIn(
                mappedName ?? (isExpanded ? theme.expandedFolder : theme.folder),
                useColoredAsset: colored && set == .complete
            )
        }

        let lowerName = node.name.lowercased()
        if let exact = byFileName[lowerName] {
            return resolveCustom(exact)
        }
        if let contains = mostSpecificContainsMatch(in: lowerName) {
            return resolveCustom(contains)
        }

        let candidates = extensionCandidates(for: lowerName)
        for candidate in candidates {
            if let replacement = byFileExtension[candidate] {
                return resolveCustom(replacement)
            }
        }

        if set != .none {
            if let exact = theme.fileNames[lowerName] {
                return resolveBuiltIn(exact, useColoredAsset: colored && set == .complete)
            }
            for candidate in candidates {
                if let mapped = theme.fileExtensions[candidate] {
                    return resolveBuiltIn(mapped, useColoredAsset: colored && set == .complete)
                }
            }
        }

        return resolveBuiltIn(
            theme.file,
            useColoredAsset: colored && set == .complete
        )
    }

    private func mostSpecificContainsMatch(in lowerName: String) -> FileTreeIcon? {
        byFileNameContains
            .filter { !$0.key.isEmpty && lowerName.contains($0.key) }
            .sorted { left, right in
                if left.key.count != right.key.count {
                    return left.key.count > right.key.count
                }
                return left.key < right.key
            }
            .first?.value
    }

    private func extensionCandidates(for lowerName: String) -> [String] {
        let components = lowerName.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count > 1 else { return [lowerName] }
        return (1..<components.count).compactMap { index in
            let candidate = components[index...].joined(separator: ".")
            return candidate.isEmpty ? nil : candidate
        }
    }

    private func resolveCustom(_ icon: FileTreeIcon) -> ResolvedFileTreeIcon {
        switch icon {
        case .builtIn(let name):
            resolveBuiltIn(name, useColoredAsset: colored)
        case .systemSymbol(let name):
            ResolvedFileTreeIcon(source: .systemSymbol(name), isTemplate: true)
        case .namedAsset(let name, let bundleIdentifier):
            ResolvedFileTreeIcon(
                source: .namedAsset(name: name, bundleIdentifier: bundleIdentifier),
                isTemplate: false
            )
        }
    }

    private func resolveBuiltIn(
        _ requestedName: String,
        useColoredAsset: Bool
    ) -> ResolvedFileTreeIcon {
        let name = FileTreeBuiltInIconCatalog.availableNames.contains(requestedName)
            ? requestedName
            : FileTreeBuiltInIconCatalog.minimal.file
        let assetName = "TreeKitIcon-\(name)\(useColoredAsset ? "-colored" : "")"
        return ResolvedFileTreeIcon(source: .builtInAsset(assetName), isTemplate: !useColoredAsset)
    }
}

#if canImport(SwiftUI)
import SwiftUI

/// Renders the same resolved file icon used by TreeKit's built-in native rows.
public struct FileTreeIconImage: View {
    public let node: FileTreePath
    public let isExpanded: Bool
    public let icons: FileTreeIcons

    public init(
        node: FileTreePath,
        isExpanded: Bool = false,
        icons: FileTreeIcons = .complete
    ) {
        self.node = node
        self.isExpanded = isExpanded
        self.icons = icons
    }

    public var body: some View {
        render(icons.resolve(node, isExpanded: isExpanded))
    }

    @ViewBuilder
    private func render(_ resolved: ResolvedFileTreeIcon) -> some View {
#if canImport(AppKit)
        if let image = resolved.appKitImage() {
            styled(Image(nsImage: image), template: resolved.isTemplate)
        }
#elseif canImport(UIKit)
        if let image = resolved.uiKitImage() {
            styled(Image(uiImage: image), template: resolved.isTemplate)
        }
#endif
    }

    private func styled(_ image: Image, template: Bool) -> some View {
        image
            .renderingMode(template ? .template : .original)
            .resizable()
            .scaledToFit()
            .foregroundStyle(.secondary)
    }
}
#endif

#if canImport(AppKit)
import AppKit

@MainActor
public extension FileTreeIcons {
    /// Resolves a native AppKit image using the same rules as the built-in row.
    func image(for node: FileTreePath, isExpanded: Bool = false) -> NSImage? {
        resolve(node, isExpanded: isExpanded).appKitImage()
    }
}

@MainActor
internal extension ResolvedFileTreeIcon {
    func appKitImage() -> NSImage? {
        let image: NSImage?
        switch source {
        case .builtInAsset(let name):
            image = Bundle.module.image(forResource: NSImage.Name(name))
                ?? Self.rawSVG(named: name)
        case .systemSymbol(let name):
            image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        case .namedAsset(let name, let bundleIdentifier):
            let bundle = bundleIdentifier.flatMap(Bundle.init(identifier:)) ?? .main
            image = bundle.image(forResource: NSImage.Name(name))
        }
        let result = image?.copy() as? NSImage
        result?.isTemplate = isTemplate
        return result
    }

    private static func rawSVG(named name: String) -> NSImage? {
        let appearance = NSApplication.shared.effectiveAppearance.bestMatch(
            from: [.darkAqua, .aqua]
        )
        let variant = appearance == .darkAqua ? "dark" : "light"
        let directory = "FileTreeIcons.xcassets/\(name).imageset"
        guard let url = Bundle.module.url(
            forResource: variant,
            withExtension: "svg",
            subdirectory: directory
        ) else { return nil }
        return NSImage(contentsOf: url)
    }
}
#elseif canImport(UIKit)
import UIKit

@MainActor
public extension FileTreeIcons {
    /// Resolves a native UIKit image using the same rules as the built-in row.
    func image(for node: FileTreePath, isExpanded: Bool = false) -> UIImage? {
        resolve(node, isExpanded: isExpanded).uiKitImage()
    }
}

@MainActor
internal extension ResolvedFileTreeIcon {
    func uiKitImage() -> UIImage? {
        let image: UIImage?
        switch source {
        case .builtInAsset(let name):
            image = UIImage(named: name, in: .module, compatibleWith: nil)
        case .systemSymbol(let name):
            image = UIImage(systemName: name)
        case .namedAsset(let name, let bundleIdentifier):
            let bundle = bundleIdentifier.flatMap(Bundle.init(identifier:)) ?? .main
            image = UIImage(named: name, in: bundle, compatibleWith: nil)
        }
        return image?.withRenderingMode(isTemplate ? .alwaysTemplate : .alwaysOriginal)
    }
}
#endif
