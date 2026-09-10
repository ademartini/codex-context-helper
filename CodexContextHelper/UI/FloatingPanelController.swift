import AppKit
import SwiftUI

private final class MonitorPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

@MainActor
final class FloatingPanelController: NSObject, NSWindowDelegate {
    let panel: NSPanel
    private let model: PanelViewModel

    init(model: PanelViewModel) {
        self.model = model
        panel = MonitorPanel(contentRect: NSRect(x: 100, y: 100, width: 360, height: 320),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.title = "Codex Context Helper"
        panel.identifier = NSUserInterfaceItemIdentifier("codex-context-helper.panel")
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.animationBehavior = .none
        panel.contentView = NSHostingView(rootView: PanelRootView(model: model))
        (panel as? MonitorPanel)?.onCancel = { [weak model] in model?.back() }
        panel.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let size = preferredSize
        let origin = model.settings.panelPosition.map { NSPoint(x: $0.x, y: $0.y) }
            ?? NSPoint(x: (NSScreen.main?.visibleFrame.maxX ?? 1000) - size.width - 24,
                       y: (NSScreen.main?.visibleFrame.maxY ?? 800) - size.height - 24)
        panel.setFrame(Self.clampedFrame(NSRect(origin: origin, size: size), screens: NSScreen.screens.map(\.visibleFrame)), display: false)
    }
    private var preferredSize: NSSize {
        if model.showsSettings || model.detailID != nil { return NSSize(width: 300, height: 560) }
        return NSSize(width: 300, height: 380)
    }
    func updateLayout() {
        var size = preferredSize
        if let screen = panel.screen {
            size.height = min(size.height, max(120, panel.frame.maxY - screen.visibleFrame.minY))
        }
        let target = NSRect(x: panel.frame.maxX - size.width, y: panel.frame.maxY - size.height, width: size.width, height: size.height)
        panel.setFrame(Self.clampedFrame(target, screens: NSScreen.screens.map(\.visibleFrame)), display: model.panelVisible)
        // Layout changes originate in explicit navigation/settings actions, never data refreshes.
        // A nonactivating panel still needs to become key to receive keyboard navigation.
        if model.panelVisible { panel.makeKey() }
    }
    func updateVisibility() {
        if model.panelVisible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }
    func showSettings() { model.show(); model.openSettings(); panel.makeKeyAndOrderFront(nil) }
    func windowDidMove(_ notification: Notification) { model.recordPosition(panel.frame.origin) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { model.hide(); return false }
    @objc private func screensChanged() { panel.setFrame(Self.clampedFrame(panel.frame, screens: NSScreen.screens.map(\.visibleFrame)), display: model.panelVisible) }

    static func clampedFrame(_ proposed: NSRect, screens: [NSRect]) -> NSRect {
        guard let first = screens.first else { return proposed }
        let screen = screens.max {
            let a = $0.intersection(proposed), b = $1.intersection(proposed)
            return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
        } ?? first
        let width = min(proposed.width, screen.width), height = min(proposed.height, screen.height)
        return NSRect(x: min(max(proposed.minX, screen.minX), screen.maxX - width),
                      y: min(max(proposed.minY, screen.minY), screen.maxY - height), width: width, height: height)
    }
}
