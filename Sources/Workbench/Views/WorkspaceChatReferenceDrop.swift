import AppKit
import SwiftUI

enum WorkspaceChatReferenceDrop {
    static let types: [NSPasteboard.PasteboardType] = [TreeRowInteraction.pasteboardType, .fileURL]

    static func urls(on pasteboard: NSPasteboard) -> [URL] {
        switch TreeRowInteraction.View.payload(on: pasteboard) {
        case .treeNodes(let paths): return paths.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0) }
        case .files(let urls): return urls
        case nil: return []
        }
    }

    static func urls(from sender: NSDraggingInfo) -> [URL] {
        guard sender.draggingSourceOperationMask.contains(.copy) else { return [] }
        return urls(on: sender.draggingPasteboard)
    }
}

/// Use AppKit's pasteboard on the whole drawer so the tree's multi-selection stays one drop.
struct WorkspaceChatDropHost<Content: View>: NSViewRepresentable {
    let content: Content
    let add: ([URL]) -> Void
    let targetChanged: (Bool) -> Void

    func makeNSView(context: Context) -> Host {
        let view = Host(rootView: content)
        view.sizingOptions = []
        view.registerForDraggedTypes(WorkspaceChatReferenceDrop.types)
        configure(view)
        return view
    }

    func updateNSView(_ view: Host, context: Context) {
        view.rootView = content
        configure(view)
    }

    private func configure(_ view: Host) {
        view.add = add
        view.targetChanged = targetChanged
    }

    final class Host: NSHostingView<Content> {
        var add: ([URL]) -> Void = { _ in }
        var targetChanged: (Bool) -> Void = { _ in }
        private var targeted = false {
            didSet { if oldValue != targeted { targetChanged(targeted) } }
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
        override func draggingExited(_ sender: NSDraggingInfo?) { targeted = false }
        override func draggingEnded(_ sender: NSDraggingInfo) { targeted = false }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            !WorkspaceChatReferenceDrop.urls(from: sender).isEmpty
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            targeted = false
            let urls = WorkspaceChatReferenceDrop.urls(from: sender)
            guard !urls.isEmpty else { return false }
            add(urls)
            return true
        }

        private func track(_ sender: NSDraggingInfo) -> NSDragOperation {
            targeted = !WorkspaceChatReferenceDrop.urls(from: sender).isEmpty
            return targeted ? .copy : []
        }
    }
}
