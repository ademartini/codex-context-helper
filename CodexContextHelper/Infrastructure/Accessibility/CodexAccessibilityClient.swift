import AppKit
import ApplicationServices

@MainActor
final class CodexAccessibilityClient {
    private let permission: AccessibilityPermissionController
    init(permission: AccessibilityPermissionController) { self.permission = permission }

    func selectionEvidence() -> TaskSelectionEvidence {
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
        while !pending.isEmpty {
            let (node, inheritedSelection) = pending.removeFirst()
            guard visited < 400, ContinuousClock.now < deadline else { return .unavailable(.unsupportedSchema) }
            visited += 1
            let selected = inheritedSelection || (attribute(node, kAXSelectedAttribute) as? Bool == true)
            let role = attribute(node, kAXRoleAttribute) as? String
            var foundIdentity = false
            if selected, [kAXRowRole, kAXButtonRole, kAXRadioButtonRole].contains(role ?? "") {
                if let identifier = attribute(node, kAXIdentifierAttribute) as? String, UUID(uuidString: identifier) != nil {
                    ids.insert(identifier)
                    foundIdentity = true
                }
                if let title = AccessibilitySelectionTraversal.taskTitle(
                    title: attribute(node, kAXTitleAttribute) as? String,
                    description: attribute(node, kAXDescriptionAttribute) as? String) {
                    titles.insert(title)
                    foundIdentity = true
                }
            }
            guard let routes = AccessibilitySelectionTraversal.childRoutes(
                selectedChildren: { attribute(node, kAXSelectedChildrenAttribute) as? [AXUIElement] },
                children: { attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] },
                selected: selected, foundIdentity: foundIdentity, pendingCount: pending.count
            ) else { return .unavailable(.unsupportedSchema) }
            pending.append(contentsOf: routes)
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

enum AccessibilitySelectionTraversal {
    static func taskTitle(title: String?, description: String?) -> String? {
        // Chromium exposes an explicit aria-label as AXDescription instead of AXTitle.
        [description, title].compactMap { $0 }.first {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 512
                && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        }
    }

    static func childRoutes<Node>(selectedChildren: () -> [Node]?, children: () -> [Node],
                                  selected: Bool, foundIdentity: Bool, pendingCount: Int) -> [(Node, Bool)]? {
        // A selected task's action buttons are not additional selected tasks.
        guard !foundIdentity else { return [] }
        if let selectedChildren = selectedChildren(), !selectedChildren.isEmpty {
            guard selectedChildren.count <= 20, pendingCount + selectedChildren.count <= 400 else { return nil }
            return selectedChildren.map { ($0, true) }
        }
        let children = children()
        guard pendingCount + children.count <= 400 else { return nil }
        // Selection can be attached to a wrapper above the identifying control.
        return children.map { ($0, selected) }
    }
}
