import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// External providers do not expose their allowed source operations through SwiftUI.
/// Propose an explicit copy for them. The native list marks drags from this process.
enum GridFileTransfer: Equatable {
    static let internalType = "com.explorer.internal-file-drag.\(UUID().uuidString.lowercased())"
    case copy, move

    static func proposed(isInternal: Bool, optionPressed: Bool) -> Self {
        isInternal && !optionPressed ? .move : .copy
    }

    static func accepted(_ proposal: Self, providers: [NSItemProvider]) -> Self {
        proposal == .move && !providers.isEmpty && providers.allSatisfy {
            $0.hasItemConformingToTypeIdentifier(internalType)
        } ? .move : .copy
    }
}

struct GridFileDrop: DropDelegate {
    @Binding var proposedTransfer: GridFileTransfer?
    var isEnabled = true
    let receive: ([NSItemProvider], GridFileTransfer) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        isEnabled && info.hasItemsConforming(to: [UTType.fileURL])
    }

    func dropEntered(info: DropInfo) {
        proposedTransfer = transfer(for: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let transfer = transfer(for: info)
        proposedTransfer = transfer
        return DropProposal(operation: transfer == .copy ? .copy : .move)
    }

    func dropExited(info: DropInfo) {
        proposedTransfer = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { proposedTransfer = nil }
        guard validateDrop(info: info) else { return false }
        let providers = info.itemProviders(for: [UTType.fileURL])
        guard !providers.isEmpty else { return false }
        let chosen = GridFileTransfer.accepted(proposedTransfer ?? transfer(for: info), providers: providers)
        return receive(providers, chosen)
    }

    private func transfer(for info: DropInfo) -> GridFileTransfer {
        // SwiftUI only permits itemProviders(for:) during performDrop.
        .proposed(isInternal: info.hasItemsConforming(to: [GridFileTransfer.internalType]),
                  optionPressed: NSEvent.modifierFlags.contains(.option))
    }
}
