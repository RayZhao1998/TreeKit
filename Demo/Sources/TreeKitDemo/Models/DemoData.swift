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

enum DemoRowStyle: String, CaseIterable, Identifiable {
  case custom
  case builtIn

  var id: Self { self }

  var title: String {
    switch self {
    case .custom: "Custom"
    case .builtIn: "Built-in"
    }
  }
}

enum DemoPathSort: String, CaseIterable, Identifiable {
  case foldersFirst
  case lexicographic
  case inputOrder

  var id: Self { self }

  var title: String {
    switch self {
    case .foldersFirst: "Folders first"
    case .lexicographic: "Lexicographic"
    case .inputOrder: "Input order"
    }
  }

  var treeKitValue: FileTreePathOptions.Sort {
    switch self {
    case .foldersFirst: .foldersFirst
    case .lexicographic: .lexicographic
    case .inputOrder: .inputOrder
    }
  }
}

enum DemoGitStatus: String, Decodable, Sendable {
  case modified = "M"
  case added = "A"
  case deleted = "D"
  case renamed = "R"

  var title: String {
    switch self {
    case .modified: "Modified"
    case .added: "Added"
    case .deleted: "Deleted"
    case .renamed: "Renamed"
    }
  }
}

enum DemoData {
  private struct Fixture: Decodable {
    let repository: String
    let pullRequest: Int
    let title: String
    let sourceURL: String
    let changedFiles: Int
    let files: [ChangedFile]
  }

  private struct ChangedFile: Decodable {
    let path: String
    let status: DemoGitStatus
  }

  private static let fixture = loadFixture()

  static let repository = fixture.repository
  static let pullRequest = fixture.pullRequest
  static let title = fixture.title
  static let sourceURL = URL(string: fixture.sourceURL)!
  static let changedFileCount = fixture.changedFiles
  static let paths = fixture.files.map(\.path)
  static let gitStatuses = Dictionary(
    uniqueKeysWithValues: fixture.files.map { ($0.path, $0.status) }
  )

  static let initialSelection = "src/bun.zig"
  static let revealTarget = "src/runtime/cli/cli.zig"
  static let performanceTargets: [String] = {
    let sampleCount = min(300, paths.count)
    guard sampleCount > 1 else { return paths }

    let forward = (0..<sampleCount).map { index in
      paths[index * (paths.count - 1) / (sampleCount - 1)]
    }
    return forward + forward.reversed()
  }()

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

  private static func loadFixture() -> Fixture {
    guard let url = Bundle.module.url(
      forResource: "BunPR30412",
      withExtension: "json"
    ) else {
      fatalError("Missing Bun PR #30412 demo fixture")
    }

    do {
      let fixture = try JSONDecoder().decode(
        Fixture.self,
        from: Data(contentsOf: url)
      )
      guard fixture.files.count == fixture.changedFiles else {
        fatalError(
          "Bun PR #30412 fixture declares \(fixture.changedFiles) files "
            + "but contains \(fixture.files.count)"
        )
      }
      return fixture
    } catch {
      fatalError("Invalid Bun PR #30412 demo fixture: \(error.localizedDescription)")
    }
  }
}
