import Testing
@testable import TreeKit

struct FileTreeIconTests {
    @Test
    func completeSetUsesExactNamesAndFrameworkSpecificExtensions() throws {
        let package = try FileTreePath(path: "package.json")
        let component = try FileTreePath(path: "Button.tsx")
        let source = try FileTreePath(path: "index.ts")

        #expect(
            FileTreeIcons.complete.resolve(package, isExpanded: false).source
                == .builtInAsset("TreeKitIcon-npm-colored")
        )
        #expect(
            FileTreeIcons.complete.resolve(component, isExpanded: false).source
                == .builtInAsset("TreeKitIcon-react-colored")
        )
        #expect(
            FileTreeIcons.complete.resolve(source, isExpanded: false).source
                == .builtInAsset("TreeKitIcon-lang-typescript-duo-colored")
        )
    }

    @Test
    func standardSetUsesMonochromeLanguageIcons() throws {
        let component = try FileTreePath(path: "Button.tsx")
        let resolved = FileTreeIcons.standard.resolve(component, isExpanded: false)

        #expect(resolved.source == .builtInAsset("TreeKitIcon-lang-typescript-duo"))
        #expect(resolved.isTemplate)
    }

    @Test
    func targetedRulesUseDocumentedSpecificity() throws {
        let icons = FileTreeIcons(
            set: .none,
            byFileName: ["BUTTON.SPEC.TS": .systemSymbol("star")],
            byFileNameContains: ["spec": .systemSymbol("checkmark")],
            byFileExtension: [
                ".spec.ts": .systemSymbol("bolt"),
                "ts": .systemSymbol("doc")
            ]
        )

        #expect(
            icons.resolve(try FileTreePath(path: "button.spec.ts"), isExpanded: false).source
                == .systemSymbol("star")
        )
        #expect(
            icons.resolve(try FileTreePath(path: "menu.spec.ts"), isExpanded: false).source
                == .systemSymbol("checkmark")
        )

        var extensionOnly = icons
        extensionOnly.byFileNameContains = [:]
        #expect(
            extensionOnly.resolve(
                try FileTreePath(path: "menu.spec.ts"),
                isExpanded: false
            ).source == .systemSymbol("bolt")
        )
    }

    @Test
    func folderSlotsDistinguishCollapsedAndExpandedState() throws {
        let folder = try FileTreePath(path: "Sources/", kind: .directory)

        #expect(
            FileTreeIcons.complete.resolve(folder, isExpanded: false).source
                == .builtInAsset("TreeKitIcon-folder-duo-colored")
        )
        #expect(
            FileTreeIcons.complete.resolve(folder, isExpanded: true).source
                == .builtInAsset("TreeKitIcon-folder-open-duo-colored")
        )
    }

    @Test
    func explicitBuiltInIconsCanStayColoredWithoutAutomaticMappings() throws {
        let node = try FileTreePath(path: "Component.custom")
        let icons = FileTreeIcons(
            set: .none,
            colored: true,
            byFileExtension: ["custom": .builtIn("react")]
        )

        #expect(
            icons.resolve(node, isExpanded: false).source
                == .builtInAsset("TreeKitIcon-react-colored")
        )
    }

#if canImport(AppKit)
    @MainActor
    @Test
    func swiftPackageBundleLoadsVendoredSVGs() throws {
        let component = try FileTreePath(path: "Button.tsx")
        #expect(FileTreeIcons.complete.image(for: component) != nil)
    }
#endif
}
