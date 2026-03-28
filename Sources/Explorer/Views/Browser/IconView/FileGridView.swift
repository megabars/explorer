import SwiftUI
import AppKit

struct FileGridView: View {
    @Bindable var browser: BrowserViewModel
    let navigation: NavigationState
    let sidebar: SidebarViewModel

    private let columns = [GridItem(.adaptive(minimum: 80, maximum: 100), spacing: 8)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(browser.sortedItems) { item in
                    FileIconCell(
                        item: item,
                        isSelected: browser.selection.contains(item.url),
                        isCut: browser.cutURLs.contains(item.url),
                        isRenaming: browser.renamingItem?.id == item.id,
                        renameText: Binding(
                            get: { browser.renameText },
                            set: { browser.renameText = $0 }
                        ),
                        onCommitRename: { browser.commitRename(navigation: navigation) },
                        onCancelRename: { browser.cancelRename() }
                    )
                    // Double-tap must be declared before single-tap so SwiftUI tries it first.
                    .onTapGesture(count: 2) {
                        browser.open(item, navigation: navigation)
                    }
                    .onTapGesture {
                        let flags = NSApp.currentEvent?.modifierFlags ?? []
                        if flags.contains(.command) {
                            if browser.selection.contains(item.url) {
                                browser.selection.remove(item.url)
                            } else {
                                browser.selection.insert(item.url)
                            }
                            browser.lastSelectedURL = item.url
                        } else if flags.contains(.shift), let anchor = browser.lastSelectedURL {
                            let allItems = browser.sortedItems
                            if let anchorIdx = allItems.firstIndex(where: { $0.url == anchor }),
                               let targetIdx = allItems.firstIndex(where: { $0.url == item.url }) {
                                let range = min(anchorIdx, targetIdx)...max(anchorIdx, targetIdx)
                                browser.selection = Set(allItems[range].map(\.url))
                            } else {
                                browser.selection = [item.url]
                                browser.lastSelectedURL = item.url
                            }
                        } else {
                            browser.selection = [item.url]
                            browser.lastSelectedURL = item.url
                        }
                    }
                    .contextMenu {
                        Button("Open") {
                            browser.open(item, navigation: navigation)
                        }
                        if !item.isDirectory && !item.isPackage {
                            let apps = browser.openWithApps(for: item.url)
                            if !apps.isEmpty {
                                let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: item.url)
                                Menu("Open With") {
                                    ForEach(apps, id: \.self) { appURL in
                                        let name = (Bundle(url: appURL)?.infoDictionary?["CFBundleName"] as? String)
                                                   ?? appURL.deletingPathExtension().lastPathComponent
                                        Button(appURL == defaultApp ? "\(name) (default)" : name) {
                                            NSWorkspace.shared.open([item.url], withApplicationAt: appURL,
                                                                    configuration: NSWorkspace.OpenConfiguration(),
                                                                    completionHandler: nil)
                                        }
                                    }
                                }
                            }
                        }
                        Divider()
                        Button("Cut") { browser.cut() }
                        Button("Copy") { browser.copy() }
                        Button("Paste") { browser.paste(into: navigation.currentURL) }
                            .disabled(browser.clipboardItems.isEmpty)
                        Divider()
                        Button("Duplicate") { browser.duplicate() }
                        Button("Compress...") { browser.compress(currentURL: navigation.currentURL) }
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
                        // Tags submenu
                        Menu("Tags") {
                            ForEach(["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"], id: \.self) { tagName in
                                Button {
                                    var tags = item.tags
                                    if tags.contains(tagName) {
                                        tags.removeAll { $0 == tagName }
                                    } else {
                                        tags.append(tagName)
                                    }
                                    browser.setTags(tags, for: item)
                                } label: {
                                    HStack {
                                        Text(tagName)
                                        if item.tags.contains(tagName) {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                            Divider()
                            Button("None") { browser.setTags([], for: item) }
                        }
                        if item.isDirectory {
                            Divider()
                            Button("Add to Sidebar") {
                                sidebar.addFavorite(url: item.url)
                            }
                            Divider()
                            Button("Open in Terminal") {
                                guard let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
                                NSWorkspace.shared.open([item.url], withApplicationAt: terminalURL,
                                                        configuration: NSWorkspace.OpenConfiguration(),
                                                        completionHandler: nil)
                            }
                        }
                    }
                    .onDrag {
                        NSItemProvider(object: item.url as NSURL)
                    }
                }
            }
            .padding(12)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers, into: navigation.currentURL)
        }
        .onKeyPress(.leftArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            moveSelection(by: -columnsPerRow)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(by: columnsPerRow)
            return .handled
        }
        .contextMenu {
            Button("New Folder") {
                NotificationCenter.default.post(name: .newFolderRequested, object: nil)
            }
            Divider()
            Button("Paste") {
                browser.paste(into: navigation.currentURL)
            }
            .disabled(browser.clipboardItems.isEmpty)
            Divider()
            Button("Open in Terminal") {
                guard let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
                NSWorkspace.shared.open([navigation.currentURL], withApplicationAt: terminalURL,
                                        configuration: NSWorkspace.OpenConfiguration(),
                                        completionHandler: nil)
            }
        }
    }

    /// Approximate columns per row — matches the adaptive grid (minimum: 80).
    private var columnsPerRow: Int { max(1, Int(NSScreen.main?.frame.width ?? 800) / 100) }

    private func moveSelection(by offset: Int) {
        let allItems = browser.sortedItems
        guard !allItems.isEmpty else { return }
        let currentIndex: Int
        if let selectedURL = browser.selection.first,
           let idx = allItems.firstIndex(where: { $0.url == selectedURL }) {
            currentIndex = idx
        } else {
            currentIndex = -1
        }
        let newIndex = max(0, min(allItems.count - 1, currentIndex + offset))
        let item = allItems[newIndex]
        browser.selection = [item.url]
        browser.lastSelectedURL = item.url
    }

    private func handleDrop(providers: [NSItemProvider], into destination: URL) -> Bool {
        // Check if Option key is held — if so, copy instead of move
        let shouldCopy = NSEvent.modifierFlags.contains(.option)
        var handled = false
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in
                    do {
                        if shouldCopy {
                            let fileItem = FileItem(
                                id: url, url: url, name: url.lastPathComponent,
                                isDirectory: false, isPackage: false, isHidden: false,
                                isSymlink: false, fileSize: nil, contentModificationDate: nil,
                                creationDate: nil, kind: "", tags: []
                            )
                            try await FileSystemService.shared.copy(items: [fileItem], to: destination)
                        } else {
                            try await FileSystemService.shared.move(from: [url], to: destination)
                        }
                    } catch {
                        browser.errorMessage = error.localizedDescription
                    }
                }
            }
            handled = true
        }
        return handled
    }
}

private struct FileIconCell: View {
    let item: FileItem
    let isSelected: Bool
    var isCut: Bool = false
    var isRenaming: Bool = false
    var renameText: Binding<String> = .constant("")
    var onCommitRename: () -> Void = {}
    var onCancelRename: () -> Void = {}

    @FocusState private var isRenameFocused: Bool

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 48, height: 48)
                .opacity(isCut ? 0.4 : 1.0)

            if isRenaming {
                TextField("", text: renameText)
                    .font(.system(size: 11))
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .focused($isRenameFocused)
                    .onSubmit { onCommitRename() }
                    .onKeyPress(.escape) {
                        onCancelRename()
                        return .handled
                    }
                    .onAppear { isRenameFocused = true }
            } else {
                Text(item.name)
                    .font(.system(size: 11))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .truncationMode(.middle)
                    .opacity(isCut ? 0.4 : 1.0)
            }

            if !item.tags.isEmpty {
                HStack(spacing: 3) {
                    ForEach(item.tags.prefix(5), id: \.self) { tag in
                        Circle()
                            .fill(tagColor(tag))
                            .frame(width: 8, height: 8)
                    }
                }
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        )
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
    case "gray", "grey": return .gray
    default:       return .gray
    }
}
