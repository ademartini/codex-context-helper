import SwiftUI

@main
struct CodexContextHelperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { delegate.openSettings() }.keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}
