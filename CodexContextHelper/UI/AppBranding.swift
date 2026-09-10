import AppKit

@MainActor
enum AppBranding {
    static var image: NSImage {
        NSImage(named: "BrandMark") ?? NSImage(systemSymbolName: "number.square", accessibilityDescription: "Codex Context Helper")!
    }

    static var menuBarImage: NSImage {
        let image = Self.image.copy() as! NSImage
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = false
        return image
    }
}
