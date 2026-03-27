import SwiftUI
import AppKit

struct FileGridView: View {
    @Bindable var browser: BrowserViewModel
    let navigation: NavigationState

    private let columns = [GridItem(.adaptive(minimum: 80, maximum: 100), spacing: 8)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(browser.items) { item in
                    FileIconCell(
                        item: item,
                        isSelected: browser.selection.contains(item.url)
                    )
                    // Double-tap must be declared before single-tap so SwiftUI tries it first.
                    .onTapGesture(count: 2) {
                        browser.open(item, navigation: navigation)
                    }
                    .onTapGesture {
                        let flags = NSApp.currentEvent?.modifierFlags ?? []
                        if flags.contains(.command) {
                            // Cmd+Click: toggle the tapped item in the selection
                            if browser.selection.contains(item.url) {
                                browser.selection.remove(item.url)
                            } else {
                                browser.selection.insert(item.url)
                            }
                        } else {
                            browser.selection = [item.url]
                        }
                    }
                    .contextMenu {
                        Button("Open") {
                            browser.open(item, navigation: navigation)
                        }
                        Divider()
                        Button("Rename") {
                            browser.startRename(item)
                        }
                        Divider()
                        Button("Move to Trash") {
                            browser.trash(items: [item])
                        }
                        Button("Get Info") {
                            NSWorkspace.shared.activateFileViewerSelecting([item.url])
                        }
                    }
                }
            }
            .padding(12)
        }
    }
}

private struct FileIconCell: View {
    let item: FileItem
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 48, height: 48)

            Text(item.name)
                .font(.system(size: 11))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        )
    }
}
