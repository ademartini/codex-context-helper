import AppKit

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let model: PanelViewModel
    private let panel: FloatingPanelController
    private let visibility = NSMenuItem(title: "Hide Panel", action: #selector(togglePanel), keyEquivalent: "")

    init(model: PanelViewModel, panel: FloatingPanelController) {
        self.model = model; self.panel = panel
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: "Codex Context Helper")
        statusItem.button?.toolTip = "Codex Context Helper"
        let menu = NSMenu()
        menu.delegate = self
        visibility.target = self; menu.addItem(visibility)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self; menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Codex Context Helper", action: #selector(quit), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        statusItem.menu = menu
    }
    func menuWillOpen(_ menu: NSMenu) { visibility.title = model.panelVisible ? "Hide Panel" : "Show Panel" }
    @objc private func togglePanel() { if model.panelVisible { model.hide() } else { model.show() } }
    @objc private func openSettings() { panel.showSettings() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
