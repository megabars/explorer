import SwiftUI
import AppKit

struct FileInfoView: View {
    let url: URL

    enum LoadState {
        case loading
        case loaded(FileExtendedInfo)
        case failed(String)
    }

    @State private var state: LoadState = .loading
    @State private var icon: NSImage? = nil

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch state {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 200)
                case .failed(let msg):
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        Text(msg)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                case .loaded(let info):
                    loadedView(info)
                }
            }
            .padding(16)
        }
        .frame(minWidth: 280, idealWidth: 300, maxWidth: 400,
               minHeight: 350, idealHeight: 460)
        .task {
            icon = NSWorkspace.shared.icon(forFile: url.path)
            icon?.size = NSSize(width: 64, height: 64)
            do {
                let info = try await FileSystemService.shared.extendedInfo(for: url)
                state = .loaded(info)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Loaded layout

    @ViewBuilder
    private func loadedView(_ info: FileExtendedInfo) -> some View {
        // Header
        HStack(spacing: 12) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 64, height: 64)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(info.name)
                    .font(.headline)
                    .lineLimit(3)
                    .textSelection(.enabled)
                Text(info.kind)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 10)

        Divider()

        // General
        infoSection("General") {
            infoRow("Kind", info.kind)
            if let size = info.fileSize {
                infoRow("Size", FileSizeFormatter.string(fromByteCount: size))
            }
            if let count = info.directoryItemCount {
                infoRow("Contents", "\(count) item\(count == 1 ? "" : "s")")
            }
            infoRow("Where", info.parentPath)
            if let created = info.creationDate {
                infoRow("Created", Self.dateFormatter.string(from: created))
            }
            if let modified = info.modificationDate {
                infoRow("Modified", Self.dateFormatter.string(from: modified))
            }
            if info.isHidden {
                infoRow("Hidden", "Yes")
            }
        }

        // Symlink
        if info.isSymlink, let target = info.symlinkTarget {
            Divider()
            infoSection("Symlink") {
                infoRow("Target", target)
            }
        }

        // Tags
        if !info.tags.isEmpty {
            Divider()
            infoSection("Tags") {
                HStack(spacing: 6) {
                    ForEach(info.tags, id: \.self) { tag in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(tagColor(tag))
                                .frame(width: 10, height: 10)
                            Text(tag)
                                .font(.caption)
                        }
                    }
                }
                .padding(.leading, 88)
            }
        }

        // Permissions
        Divider()
        infoSection("Permissions") {
            infoRow("Mode", info.posixPermissionsString)
            infoRow("Owner", info.ownerName)
            infoRow("Group", info.groupName)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func infoSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.top, 8)
            content()
                .padding(.bottom, 4)
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private func tagColor(_ tag: String) -> Color {
    switch tag.lowercased() {
    case "red":    return .red
    case "orange": return .orange
    case "yellow": return .yellow
    case "green":  return .green
    case "blue":   return .blue
    case "purple": return .purple
    default:       return .gray
    }
}
