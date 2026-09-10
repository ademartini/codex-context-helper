@preconcurrency import ApplicationServices

@MainActor
final class AccessibilityPermissionController {
    private let check: () -> Bool
    private let prompt: () -> Bool
    init(check: @escaping () -> Bool = { AXIsProcessTrusted() },
         prompt: @escaping () -> Bool = {
             AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
         }) {
        self.check = check; self.prompt = prompt
    }
    var isGranted: Bool { check() }
    /// Invoke only from the settings control, never at launch or from a polling callback.
    @discardableResult func requestFromSettings() -> Bool { prompt() }
}
