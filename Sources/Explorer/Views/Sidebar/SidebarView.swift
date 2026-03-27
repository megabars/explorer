import SwiftUI

struct SidebarView: View {
    @Bindable var vm: SidebarViewModel
    let navigation: NavigationState

    var body: some View {
        List {
            Section("Favorites") {
                ForEach(vm.favorites) { item in
                    sidebarRow(item)
                }
            }

            if !vm.volumes.isEmpty {
                Section("Locations") {
                    ForEach(vm.volumes) { item in
                        sidebarRow(item)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 180)
        // Availability is checked asynchronously to avoid blocking the main thread with I/O.
        .task {
            await vm.refreshFavoriteAvailability()
        }
    }

    private func sidebarRow(_ item: SidebarItem) -> some View {
        let available = vm.isAvailable(item)
        return Button {
            guard available else { return }
            navigation.navigate(to: item.url)
        } label: {
            Label(item.name, systemImage: item.systemImage)
                .font(.system(size: 13))
        }
        .buttonStyle(.plain)
        .padding(.vertical, 1)
        .foregroundStyle(navigation.currentURL == item.url ? .blue : (available ? .primary : .secondary))
        .opacity(available ? 1.0 : 0.5)
        .help(available ? "" : "\(item.name) is not available")
    }
}
