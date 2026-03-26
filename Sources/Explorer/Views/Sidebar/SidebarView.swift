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
    }

    private func sidebarRow(_ item: SidebarItem) -> some View {
        Button {
            navigation.navigate(to: item.url)
        } label: {
            Label(item.name, systemImage: item.systemImage)
                .font(.system(size: 13))
        }
        .buttonStyle(.plain)
        .padding(.vertical, 1)
        .foregroundStyle(navigation.currentURL == item.url ? .blue : .primary)
    }
}
