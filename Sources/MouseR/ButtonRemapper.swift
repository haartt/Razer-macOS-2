import AppKit
import ApplicationServices

enum MouseButton: Int, CaseIterable, Identifiable {
    case middle = 2, back = 3, forward = 4
    var id: Int { rawValue }
    var title: String {
        switch self { case .middle: "Wheel click"; case .back: "Side button (rear)"; case .forward: "Side button (front)" }
    }
    var defaultsKey: String { "button.\(rawValue)" }
}

enum ButtonAction: String, CaseIterable, Identifiable {
    // App Exposé and Spaces were removed: macOS ignores synthetic keystrokes for them and offers no public trigger.
    case standard, back, forward, missionControl, dpiUp, dpiDown, dpiClutch, disabled
    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: "Default"
        case .back: "Back"
        case .forward: "Forward"
        case .missionControl: "Mission Control"
        case .dpiUp: "DPI stage up"
        case .dpiDown: "DPI stage down"
        case .dpiClutch: "Hold for low DPI"
        case .disabled: "Disabled"
        }
    }
}

/// Remaps mouse buttons with a CGEventTap. Needs Accessibility permission.
/// Note: applies to these buttons on any connected mouse.
@MainActor
final class ButtonRemapper {
    var mapping: [Int: ButtonAction] = [:] { didSet { updateTap() } }
    var onDPIAction: ((ButtonAction, Bool) -> Void)? // (action, isDown)

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    private var needsTap: Bool { mapping.values.contains { $0 != .standard } }

    func updateTap() {
        if needsTap, tap == nil, Self.isTrusted { start() }
        if !needsTap, tap != nil { stop() }
    }

    private func start() {
        let mask = (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue)
            | (1 << CGEventType.otherMouseDragged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: tapCallback, userInfo: refcon)
        else { log.error("button remap: event tap could not be created"); return }
        log.notice("button remap: active")
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil; source = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        guard let action = mapping[button], action != .standard else { return Unmanaged.passUnretained(event) }
        let isDown = type == .otherMouseDown
        if type != .otherMouseDragged { perform(action, isDown: isDown) }
        return nil // swallow the original click
    }

    private func perform(_ action: ButtonAction, isDown: Bool) {
        switch action {
        case .dpiUp, .dpiDown, .dpiClutch: onDPIAction?(action, isDown)
        // Back/Forward: run outside the event tap callback, AX calls to other apps can take a moment.
        case .back where isDown: DispatchQueue.main.async { self.navigate(.back) }
        case .forward where isDown: DispatchQueue.main.async { self.navigate(.forward) }
        // Launching the Mission Control app works; a synthetic ⌃↑ is ignored by macOS.
        case .missionControl where isDown:
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Mission Control.app"),
                                               configuration: NSWorkspace.OpenConfiguration())
        default: break
        }
    }

    enum Direction {
        case back, forward
        var titles: Set<String> { self == .back ? ["back", "indietro"] : ["forward", "avanti"] }
        var usChar: String { self == .back ? "[" : "]" }
    }

    /// Presses the frontmost app's own Back/Forward menu item (Safari: History, Finder: Go, Chrome: History).
    /// Keystrokes can't be used: macOS localizes these shortcuts per keyboard layout
    /// (Italian: ⌘ò / ⌘à instead of ⌘[ / ⌘]), and the key positions differ too.
    private func navigate(_ dir: Direction) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.5)
        guard let bar: AXUIElement = attribute(axApp, kAXMenuBarAttribute),
              let item = findNavItem(in: bar, dir)
        else {
            log.notice("nav \(String(describing: dir), privacy: .public): no menu item in \(app.localizedName ?? "?", privacy: .public)")
            return
        }
        AXUIElementPerformAction(item, kAXPressAction as CFString)
        log.notice("nav \(String(describing: dir), privacy: .public): pressed in \(app.localizedName ?? "?", privacy: .public)")
    }

    /// Looks only at top-level menu items (menu bar → menu → item), never submenus such as history entries.
    private func findNavItem(in bar: AXUIElement, _ dir: Direction) -> AXUIElement? {
        let menus: [AXUIElement] = (attribute(bar, kAXChildrenAttribute) as [AXUIElement]? ?? [])
            .flatMap { attribute($0, kAXChildrenAttribute) as [AXUIElement]? ?? [] }
        for menu in menus {
            for item in attribute(menu, kAXChildrenAttribute) as [AXUIElement]? ?? [] {
                // No "enabled" check: AppKit only updates it when the menu is opened, so it reads stale (false).
                guard let char: String = attribute(item, kAXMenuItemCmdCharAttribute), !char.isEmpty,
                      (attribute(item, kAXMenuItemCmdModifiersAttribute) as Int?) == 0 // ⌘ only
                else { continue }
                let title = (attribute(item, kAXTitleAttribute) as String? ?? "").lowercased()
                if dir.titles.contains(title) || char == dir.usChar { return item }
            }
        }
        return nil
    }

    private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

}

private func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let remapper = Unmanaged<ButtonRemapper>.fromOpaque(refcon).takeUnretainedValue()
    return MainActor.assumeIsolated { remapper.handle(type: type, event: event) }
}
