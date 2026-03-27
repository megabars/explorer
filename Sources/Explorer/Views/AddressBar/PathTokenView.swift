import SwiftUI
import AppKit

/// A single breadcrumb segment. Clicking it navigates to that directory.
struct PathTokenView: View {
    let url: URL
    let isLast: Bool
    let onTap: (URL) -> Void

    @State private var resolvedName: String = ""

    private var isRoot: Bool { url.pathComponents.count <= 1 }

    private var icon: String {
        if isRoot { return "externaldrive" }
        let home = FileManager.default.homeDirectoryForCurrentUser
        if url == home { return "house" }
        return "folder"
    }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                onTap(url)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: icon)
                        .font(.system(size: 10))
                        .foregroundStyle(isLast ? .primary : .secondary)

                    Text(resolvedName.isEmpty ? url.lastPathComponent : resolvedName)
                        .font(.system(size: 12, weight: isLast ? .medium : .regular))
                        .foregroundStyle(isLast ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isLast ? Color.primary.opacity(0.08) : Color.clear)
                )
            }
            .buttonStyle(.plain)

            if !isLast {
                Text("›")
                    .font(.system(size: 13, weight: .light))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 1)
            }
        }
        // Resolve the display name asynchronously to avoid blocking the main thread with I/O.
        // task(id: url) re-runs whenever the url changes.
        .task(id: url) {
            if isRoot {
                // Volume name lookup is I/O — runs on the FileSystemService actor.
                let name = await FileSystemService.shared.volumeName(for: url)
                resolvedName = name ?? url.lastPathComponent
            } else {
                resolvedName = url.lastPathComponent
            }
        }
    }
}
