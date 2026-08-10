import SwiftUI
import TreeKit

struct CustomFileTreeRow: View {
  let node: FileTreePath
  let context: FileTreeRowContext<String>
  let gitStatus: DemoGitStatus?
  let icons: FileTreeIcons

  var body: some View {
    HStack(spacing: 7) {
      FileTreeIconImage(
        node: node,
        isExpanded: context.isExpanded,
        icons: icons
      )
      .frame(width: 16, height: 16)

      Text(context.displayedPathSegments.joined(separator: " / "))
        .lineLimit(1)
        .truncationMode(.middle)

      Spacer(minLength: 8)

      if context.isSearchMatch {
        Image(systemName: "magnifyingglass.circle.fill")
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
          .help("Search match")
      }

      if context.isFocused {
        Image(systemName: "keyboard")
          .font(.system(size: 10))
          .foregroundStyle(.tint)
          .help("Focused command target")
      }

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

extension DemoGitStatus {
  var color: Color {
    switch self {
    case .modified: .orange
    case .added: .green
    case .deleted: .red
    case .renamed: .blue
    }
  }
}
