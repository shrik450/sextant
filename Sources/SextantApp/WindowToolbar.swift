import AppKit

/// The toolbar holds the sidebar toggle and a few plain buttons beside the traffic lights, and the
/// inspector toggle at the far end, so the panes' cards rise to the top of the window between
/// them.
extension RepoWindowController: NSToolbarDelegate {
    static let goToAnythingID = NSToolbarItem.Identifier("goToAnything")
    static let findInFilesID = NSToolbarItem.Identifier("findInFiles")
    static let inspectorToggleID = NSToolbarItem.Identifier("inspectorToggle")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, RepoWindowController.findInFilesID, RepoWindowController.goToAnythingID, .sidebarTrackingSeparator,
         .flexibleSpace, RepoWindowController.inspectorToggleID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case RepoWindowController.goToAnythingID:
            buttonItem(id, "Go to Anything", symbol: "magnifyingglass", shortcut: "⌘K", action: #selector(goToAnything(_:)))
        case RepoWindowController.findInFilesID:
            buttonItem(id, "Find in Files", symbol: "text.page.badge.magnifyingglass", shortcut: "⇧⌘F", action: #selector(findInRepository(_:)))
        case RepoWindowController.inspectorToggleID:
            buttonItem(id, "Inspector", symbol: "sidebar.right", shortcut: "⌥⌘0", action: #selector(toggleInspectorColumn(_:)))
        default:
            nil
        }
    }

    private func buttonItem(_ id: NSToolbarItem.Identifier, _ label: String, symbol: String, shortcut: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
        button.bezelStyle = .toolbar
        item.view = button
        item.label = label
        item.toolTip = "\(label) (\(shortcut))"
        return item
    }

    /// The window-space frames of the titlebar controls that can sit over the cards' row: the
    /// traffic lights and the buttons beside them, and the inspector toggle.
    var titlebarControlFrames: [NSRect] {
        guard let window, let items = window.toolbar?.items else { return [] }
        func frame(_ id: NSToolbarItem.Identifier) -> NSRect? {
            guard let v = items.first(where: { $0.itemIdentifier == id })?.view, v.window != nil else { return nil }
            return v.convert(v.bounds, to: nil)
        }
        let width = window.frame.width
        var frames: [NSRect] = []
        if let last = frame(RepoWindowController.goToAnythingID) { frames.append(NSRect(x: 0, y: last.minY, width: last.maxX, height: last.height)) }
        if let toggle = frame(RepoWindowController.inspectorToggleID) { frames.append(NSRect(x: toggle.minX, y: toggle.minY, width: width - toggle.minX, height: toggle.height)) }
        return frames
    }

    /// Shows or hides the inspector beside the panes.
    @objc func toggleInspectorColumn(_ sender: Any?) {
        let item = split.splitViewItems[2]
        item.animator().isCollapsed = !item.isCollapsed
    }
}
