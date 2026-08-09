import SwiftUI
import TreeKit

struct CustomFileTreeRow: View {
  let node: FileTreePath
  let context: FileTreeRowContext<String>
  let gitStatus: DemoGitStatus?

  var body: some View {
    HStack(spacing: 7) {
      Image(systemName: node.demoSymbolName(isExpanded: context.isExpanded))
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(node.demoIconColor)
        .frame(width: 16)

      Text(node.name)
        .lineLimit(1)
        .truncationMode(.middle)

      Spacer(minLength: 8)

      if let gitStatus {
        Text(gitStatus.rawValue)
          .font(.system(size: 10, weight: .bold, design: .rounded))
          .foregroundStyle(gitStatus.color)
          .frame(width: 16)
          .help(gitStatus.title)
      }
    }
    .padding(.trailing, 7)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }
}

extension FileTreePath {
  func demoSymbolName(isExpanded: Bool = false) -> String {
    if kind == .directory {
      return isExpanded ? "folder.fill" : "folder"
    }

    return switch URL(fileURLWithPath: name).pathExtension.lowercased() {
    case "swift": "swift"
    case "md": "doc.richtext"
    case "png", "jpg", "jpeg": "photo"
    case "yml", "yaml": "gearshape.2"
    default: name == "Package.swift" ? "shippingbox" : "doc"
    }
  }

  var demoIconColor: Color {
    if kind == .directory {
      return .accentColor
    }
    return name.hasSuffix(".swift") ? .orange : .secondary
  }
}

extension DemoGitStatus {
  var color: Color {
    switch self {
    case .modified: .orange
    case .added: .green
    case .untracked: .blue
    }
  }
}
