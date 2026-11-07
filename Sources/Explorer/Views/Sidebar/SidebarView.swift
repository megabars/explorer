import SwiftUI

struct SidebarView: View {
    @Bindable var vm: SidebarViewModel
    let navigation: NavigationState
    @State private var activationRevision = 0
    @State private var pendingNavigation: Task<Void, Never>?

    private struct AvailabilityRequest: Equatable {
        let favorites: [URL]
        let volumes: [URL]
        let navigationRevision: UInt64
        let activationRevision: Int
    }

    var body: some View {
        List {
            Section(L10n.text("Favorites")) {
                ForEach(vm.favorites) { item in
                    sidebarRow(item)
                }
            }

            if !vm.volumes.isEmpty {
                Section(L10n.text("Locations")) {
                    ForEach(vm.volumes) { item in
                        sidebarRow(item)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 180)
        // Availability is checked asynchronously to avoid blocking the main thread with I/O.
        .task(id: AvailabilityRequest(
            favorites: vm.favorites.map(\.id),
            volumes: vm.volumes.map(\.id),
            navigationRevision: navigation.revision,
            activationRevision: activationRevision
        )) {
            await vm.refreshFavoriteAvailability()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            activationRevision += 1
        }
        .onDisappear {
            pendingNavigation?.cancel()
        }
    }

    private func sidebarRow(_ item: SidebarItem) -> some View {
        let available = vm.isAvailable(item)
        return Button {
            pendingNavigation?.cancel()
            if item.section == .locations {
                navigation.navigate(to: item.url)
            } else {
                let revision = navigation.revision
                pendingNavigation = Task {
                    guard await vm.refreshAvailability(for: item),
                          navigation.revision == revision, !Task.isCancelled else { return }
                    navigation.navigate(to: item.url)
                }
            }
        } label: {
            Label(item.name, systemImage: item.systemImage)
                .font(.system(size: 13))
        }
        .buttonStyle(.plain)
        .padding(.vertical, 1)
        .foregroundStyle(navigation.isCurrentLocation(item.url) ? .blue : (available ? .primary : .secondary))
        .opacity(available ? 1.0 : 0.5)
        .help(available ? "" : L10n.format("%@ is not available", item.name))
        .contextMenu(item.section == .favorites ? ContextMenu {
            Button(L10n.text("Remove from Sidebar"), role: .destructive) {
                vm.removeFavorite(id: item.id)
            }
        } : nil)
    }
}
