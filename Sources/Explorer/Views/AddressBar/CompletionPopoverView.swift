import SwiftUI

struct CompletionPopoverView: View {
    let completions: [URL]
    let onSelect: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(completions.enumerated()), id: \.element) { index, url in
                Button {
                    onSelect(url)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        Text(url.lastPathComponent)
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(Color.clear)

                if index < completions.count - 1 {
                    Divider().padding(.horizontal, 8)
                }
            }
        }
        .frame(minWidth: 280)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 6)
    }
}
