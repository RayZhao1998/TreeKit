import Foundation
import TreeKit

enum DemoRenderer: String, CaseIterable, Identifiable {
  case swiftUI
  case appKit

  var id: Self { self }

  var title: String {
    switch self {
    case .swiftUI: "SwiftUI"
    case .appKit: "AppKit"
    }
  }

  var componentName: String {
    switch self {
    case .swiftUI: "FileTree · custom row"
    case .appKit: "FileTreeView · native row"
    }
  }
}

enum DemoGitStatus: String, Sendable {
  case modified = "M"
  case added = "A"
  case untracked = "U"

  var title: String {
    switch self {
    case .modified: "Modified"
    case .added: "Added"
    case .untracked: "Untracked"
    }
  }
}

enum DemoData {
  static let paths = [
    "Sources/TreeKit/AppKit/FileTreeView+AppKit.swift",
    "Sources/TreeKit/UIKit/UIKitFileTreeView.swift",
    "Sources/TreeKit/SwiftUI/FileTree.swift",
    "Sources/TreeKit/TreeKit.docc/TreeKit.md",
    "Sources/TreeKit/FileTreeConfiguration.swift",
    "Sources/TreeKit/FileTreeModel.swift",
    "Sources/TreeKit/FileTreePath.swift",
    "Sources/TreeKit/FileTreeTypes.swift",
    "Sources/TreeKit/PreparedTree.swift",
    "Tests/TreeKitTests/FileTreeModelTests.swift",
    "Tests/TreeKitTests/FileTreePathTests.swift",
    "Tests/TreeKitTests/PreparedTreeTests.swift",
    "Resources/Preview/TreeKit-Dark.png",
    "Resources/Preview/TreeKit-Light.png",
    "Resources/SampleProject/Assets.xcassets/",
    "LICENSE",
    "Package.swift",
    "README.md",
  ]

  static let initialSelection = "Sources/TreeKit/FileTreeModel.swift"
  static let revealTarget = "Sources/TreeKit/AppKit/FileTreeView+AppKit.swift"

  static let gitStatuses: [String: DemoGitStatus] = [
    "Sources/TreeKit/FileTreeModel.swift": .modified,
    "Sources/TreeKit/SwiftUI/FileTree.swift": .modified,
    "Sources/TreeKit/UIKit/UIKitFileTreeView.swift": .added,
    "Tests/TreeKitTests/FileTreePathTests.swift": .untracked,
    "README.md": .modified,
  ]

  @MainActor
  static func makeModel() -> FileTreeModel<FileTreePath> {
    do {
      return try FileTreeModel(
        paths: paths,
        initialExpansion: .depth(2),
        initialSelection: Set([initialSelection])
      )
    } catch {
      fatalError("Invalid demo tree: \(error.localizedDescription)")
    }
  }
}
