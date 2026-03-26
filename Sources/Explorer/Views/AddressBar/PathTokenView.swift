import SwiftUI
import AppKit

/// A single breadcrumb segment. Clicking it navigates to that directory.
struct PathTokenView: View {
    let url: URL
    let isLast: Bool
    let onTap: (URL) -> Void

    private var name: String {
        let components = url.pathComponents
        if components.count <= 1 {
            // Root — show volume name
            let volumeName = (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "Macintosh HD"
            return volumeName
        }
        return url.lastPathComponent
    }

    private var icon: String {
        let components = url.pathComponents
        if components.count <= 1 { return "externaldrive" }
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

                    Text(name)
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
    }
}
