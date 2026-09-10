import AppKit
import ApplicationServices

@MainActor
final class CodexAccessibilityClient {
    private let permission: AccessibilityPermissionController
    init(permission: AccessibilityPermissionController) { self.permission = permission }

    func selectionEvidence() -> AccessibilityEvidence {
        guard permission.isGranted else { return .unavailable(.permissionDenied) }
        guard let application = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").first else {
            return .unavailable(.disconnected)
        }
        let app = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.05)
        guard let window = element(app, kAXMainWindowAttribute) else { return .unavailable(.unsupportedSchema) }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(120))
        var pending: [(AXUIElement, Bool)] = [(window, false)]
        var visited = 0
        var ids = Set<String>(), titles = Set<String>()
        while let (node, inheritedSelection) = pending.popLast() {
            guard visited < 400, ContinuousClock.now < deadline else { return .unavailable(.unsupportedSchema) }
            visited += 1
            let selected = inheritedSelection || (attribute(node, kAXSelectedAttribute) as? Bool == true)
            let role = attribute(node, kAXRoleAttribute) as? String
            if selected, [kAXRowRole, kAXButtonRole, kAXRadioButtonRole].contains(role ?? "") {
                if let identifier = attribute(node, kAXIdentifierAttribute) as? String, UUID(uuidString: identifier) != nil { ids.insert(identifier) }
                if let title = attribute(node, kAXTitleAttribute) as? String, !title.isEmpty { titles.insert(title) }
            }
            if let selectedChildren = attribute(node, kAXSelectedChildrenAttribute) as? [AXUIElement] {
                pending.append(contentsOf: selectedChildren.prefix(20).map { ($0, true) })
                if selectedChildren.count > 20 { return .unavailable(.unsupportedSchema) }
            } else if let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] {
                guard pending.count + children.count <= 400 else { return .unavailable(.unsupportedSchema) }
                pending.append(contentsOf: children.map { ($0, false) })
            }
        }
        guard !ids.isEmpty || !titles.isEmpty else { return .unavailable(.unsupportedSchema) }
        return .selected(ids: ids, titles: titles)
    }
    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }
    private func element(_ parent: AXUIElement, _ key: String) -> AXUIElement? {
        guard let value = attribute(parent, key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
