import SwiftUI
import AppKit

struct FileGridView: View {
    @Bindable var browser: BrowserViewModel
    let navigation: NavigationState
    let sidebar: SidebarViewModel

    @FocusState private var isGridFocused: Bool
    @State private var gridWidth: CGFloat = 0
    @State private var proposedTransfer: GridFileTransfer?

    private let columns = [GridItem(.adaptive(minimum: 80, maximum: 100), spacing: 8)]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(browser.sortedItems) { item in
                        icon(for: item)
                    }
                }
                .padding(12)
                .background(GeometryReader { geometry in
                    Color.clear
                        .onAppear { gridWidth = geometry.size.width }
                        .onChange(of: geometry.size.width) { _, width in gridWidth = width }
                })
            }
            .focusable()
            .focused($isGridFocused)
            .focusEffectDisabled()
            .onAppear {
                isGridFocused = browser.renamingItem == nil
                if let id = browser.renamingItem?.id { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: browser.renamingItem?.id) { _, id in
                if let id {
                    isGridFocused = false
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onChange(of: browser.lastSelectedURL) { _, url in
                if let url, isGridFocused { proxy.scrollTo(url) }
            }
            .onDrop(of: [.fileURL], delegate: GridFileDrop(proposedTransfer: $proposedTransfer) { providers, transfer in
                handleDrop(providers: providers, into: navigation.currentURL, transfer: transfer)
            })
            .onKeyPress(.leftArrow, phases: [.down, .repeat]) { key in
                guard browser.renamingItem == nil, !ExplorerCommand.isEditingText else { return .ignored }
                moveSelection(by: -1, extending: key.modifiers.contains(.shift))
                return .handled
            }
            .onKeyPress(.rightArrow, phases: [.down, .repeat]) { key in
                guard browser.renamingItem == nil, !ExplorerCommand.isEditingText else { return .ignored }
                moveSelection(by: 1, extending: key.modifiers.contains(.shift))
                return .handled
            }
            .onKeyPress(.upArrow, phases: [.down, .repeat]) { key in
                guard browser.renamingItem == nil, !ExplorerCommand.isEditingText else { return .ignored }
                moveSelection(by: -columnsPerRow, extending: key.modifiers.contains(.shift))
                return .handled
            }
            .onKeyPress(.downArrow, phases: [.down, .repeat]) { key in
                guard browser.renamingItem == nil, !ExplorerCommand.isEditingText else { return .ignored }
                moveSelection(by: columnsPerRow, extending: key.modifiers.contains(.shift))
                return .handled
            }
            .contextMenu {
                Button(L10n.text("New Folder")) {
                    browser.newFolder(in: navigation.currentURL)
                }
                Divider()
                Button(L10n.text("Paste")) {
                    browser.paste(into: navigation.currentURL)
                }
                .disabled(!browser.canPaste)
                Divider()
                Button(L10n.text("Open in Terminal")) {
                    FileOpening.openTerminal(at: navigation.currentURL) { browser.errorMessage = $0 }
                }
            }
        }
    }

    private func icon(for item: FileItem) -> some View {
        FileIconCell(
            item: item,
            isSelected: browser.selection.contains(item.url),
            isCut: browser.cutURLs.contains(item.url),
            isRenaming: browser.renamingItem?.id == item.id,
            renameText: Binding(
                get: { browser.renamingItem?.id == item.id ? browser.renameText : item.name },
                set: { text in
                    guard browser.renamingItem?.id == item.id else { return }
                    browser.renameText = text
                }
            ),
            onCommitRename: { restoreFocus in
                guard browser.renamingItem?.id == item.id else { return }
                browser.commitRename(navigation: navigation)
                if restoreFocus { isGridFocused = true }
            },
            onCancelRename: {
                guard browser.renamingItem?.id == item.id else { return }
                browser.cancelRename()
                isGridFocused = true
            }
        )
        // Double-tap must be declared before single-tap so SwiftUI tries it first.
        .onTapGesture(count: 2) {
            browser.open(item, navigation: navigation)
        }
        .onTapGesture { select(item) }
        .contextMenu { itemMenu(for: item) }
        .onDrag {
            // Legacy SwiftUI advertises copy only; do not offer the native-list move marker.
            return NSItemProvider(object: item.url as NSURL)
        }
        .onDrop(of: [.fileURL], delegate: GridFileDrop(proposedTransfer: $proposedTransfer, isEnabled: item.isDirectory && !item.isPackage) { providers, transfer in
            return handleDrop(providers: providers, into: item.url, transfer: transfer)
        })
    }

    private func select(_ item: FileItem) {
        if browser.renamingItem?.id != item.id { isGridFocused = true }
        keyboardAnchor = nil
        keyboardCursor = nil
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

    @ViewBuilder
    private func itemMenu(for item: FileItem) -> some View {
        Button(L10n.text("Open")) {
            browser.open(item, navigation: navigation)
        }
        if !item.isDirectory && !item.isPackage {
            let apps = browser.openWithApps(for: item.url)
            if !apps.isEmpty {
                let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: item.url)
                Menu(L10n.text("Open With")) {
                    ForEach(apps, id: \.self) { appURL in
                        let name = (Bundle(url: appURL)?.infoDictionary?["CFBundleName"] as? String)
                                   ?? appURL.deletingPathExtension().lastPathComponent
                        Button(appURL == defaultApp ? L10n.format("%@ (default)", name) : name) {
                            FileOpening.open([item.url], with: appURL) { browser.errorMessage = $0 }
                        }
                    }
                }
            }
        }
        Divider()
        Button(L10n.text("Cut")) {
            selectForContextAction(item)
            browser.cut()
        }
        Button(L10n.text("Copy")) {
            selectForContextAction(item)
            browser.copy()
        }
        Button(L10n.text("Paste")) { browser.paste(into: navigation.currentURL) }
            .disabled(!browser.canPaste)
        Divider()
        Button(L10n.text("Duplicate")) {
            selectForContextAction(item)
            browser.duplicate()
        }
        Button(L10n.text("Compress...")) {
            selectForContextAction(item)
            browser.compress(currentURL: navigation.currentURL)
        }
        Divider()
        Button(L10n.text("Rename")) {
            browser.startRename(item)
        }
        Divider()
        Button(L10n.text("Move to Trash")) {
            selectForContextAction(item)
            browser.trash(items: browser.selectedItems)
        }
        Button(L10n.text("Get Info")) {
            ExplorerFileInfo.show(for: item)
        }
        // Tags submenu
        Menu(L10n.text("Tags")) {
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
                        Text(L10n.text(tagName))
                        if item.tags.contains(tagName) {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            Divider()
            Button(L10n.text("None")) { browser.setTags([], for: item) }
        }
        if item.isDirectory {
            Divider()
            Button(L10n.text("Add to Sidebar")) {
                sidebar.addFavorite(url: item.url)
            }
            Divider()
            Button(L10n.text("Open in Terminal")) {
                FileOpening.openTerminal(at: item.url) { browser.errorMessage = $0 }
            }
        }
    }

    private var columnsPerRow: Int { GridNavigation.columns(for: gridWidth) }

    private func selectForContextAction(_ item: FileItem) {
        keyboardAnchor = nil
        keyboardCursor = nil
        guard !browser.selection.contains(item.url) else { return }
        browser.selection = [item.url]
        browser.lastSelectedURL = item.url
    }

    @State private var keyboardAnchor: URL?
    @State private var keyboardCursor: URL?

    private func moveSelection(by offset: Int, extending: Bool) {
        let allItems = browser.sortedItems
        guard !allItems.isEmpty else { return }
        if keyboardCursor != browser.lastSelectedURL || keyboardCursor.map({ !browser.selection.contains($0) }) == true {
            keyboardAnchor = nil
            keyboardCursor = nil
        }
        let selectedIndex = GridNavigation.selectedIndex(
            items: allItems.map(\.url), selection: browser.selection,
            preferred: extending ? keyboardCursor ?? browser.lastSelectedURL : browser.lastSelectedURL
        )
        let newIndex = GridNavigation.nextIndex(current: selectedIndex, offset: offset, count: allItems.count)
        let item = allItems[newIndex]
        if extending, let selectedIndex {
            let anchor = keyboardAnchor.flatMap { url in allItems.firstIndex { $0.url == url } } ?? selectedIndex
            keyboardAnchor = allItems[anchor].url
            browser.selection = Set(allItems[min(anchor, newIndex)...max(anchor, newIndex)].map(\.url))
        } else {
            keyboardAnchor = nil
            browser.selection = [item.url]
        }
        keyboardCursor = item.url
        browser.lastSelectedURL = item.url
    }

    private func handleDrop(providers: [NSItemProvider], into destination: URL, transfer: GridFileTransfer) -> Bool {
        guard !providers.isEmpty else { return false }
        let shouldCopy = transfer == .copy
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, error in
                let url: URL?
                if let value = item as? URL {
                    url = value
                } else if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = nil
                }
                guard error == nil, let url, url.isFileURL, url.path.hasPrefix("/") else {
                    let reason = error?.localizedDescription
                        ?? L10n.text("The drag did not provide an absolute file URL.")
                    Task { @MainActor in
                        browser.errorMessage = L10n.format("Could not read a dropped file. %@", reason)
                    }
                    return
                }
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
        }
        return true
    }
}

private struct FileIconCell: View {
    let item: FileItem
    let isSelected: Bool
    var isCut: Bool = false
    var isRenaming: Bool = false
    var renameText: Binding<String> = .constant("")
    var onCommitRename: (Bool) -> Void = { _ in }
    var onCancelRename: () -> Void = {}

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 48, height: 48)
                .opacity(isCut ? 0.4 : 1.0)

            if isRenaming {
                FocusedTextField(
                    text: renameText.wrappedValue,
                    mode: .rename(onFocusLost: { onCommitRename(false) }),
                    showsPopover: false,
                    focusRequest: 0,
                    onCommit: { onCommitRename(true) },
                    onCancel: onCancelRename,
                    onTextChange: { renameText.wrappedValue = $0 }
                )
                .frame(width: 90, height: 22)
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
