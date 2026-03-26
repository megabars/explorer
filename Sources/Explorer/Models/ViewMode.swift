enum ViewMode: String, CaseIterable {
    case list = "list"
    case icons = "icons"

    var systemImage: String {
        switch self {
        case .list: return "list.bullet"
        case .icons: return "square.grid.2x2"
        }
    }

    var label: String {
        switch self {
        case .list: return "List"
        case .icons: return "Icons"
        }
    }
}
