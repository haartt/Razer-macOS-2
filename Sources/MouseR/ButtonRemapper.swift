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

/// What the event tap callback reads. The tap runs on its own thread, so a busy main thread
/// (USB reads, UI, Accessibility calls) can never hold up mouse events: the callback only decides
/// pass or swallow and returns at once; the action itself runs later on the main thread.
final class TapContext: @unchecked Sendable {
    private let lock = NSLock()
    private var _mapping: [Int: ButtonAction] = [:]
    var mapping: [Int: ButtonAction] {
        get { lock.withLock { _mapping } }
        set { lock.withLock { _mapping = newValue } }
    }
    var tap: CFMachPort?
    var runLoop: CFRunLoop?
    var onAction: ((ButtonAction, Bool) -> Void)? // (action, isDown), called on the main thread
}

/// Remaps mouse buttons with a CGEventTap. Needs Accessibility permission.
/// Note: applies to these buttons on any connected mouse.
@MainActor
final class ButtonRemapper {
    var mapping: [Int: ButtonAction] = [:] { didSet { ctx.mapping = mapping; updateTap() } }
    var onDPIAction: ((ButtonAction, Bool) -> Void)? // (action, isDown)

    private let ctx = TapContext()

    init() {
        ctx.onAction = { [weak self] action, down in
            MainActor.assumeIsolated { self?.perform(action, isDown: down) }
        }
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    private var needsTap: Bool { mapping.values.contains { $0 != .standard } }

    /// The tap runs only while a button is remapped AND Accessibility is granted.
    func updateTap() {
        let wanted = needsTap && Self.isTrusted
        if wanted, ctx.tap == nil { start() }
        if !wanted, ctx.tap != nil { stop() }
    }

    /// Removes the tap at once, e.g. before Accessibility is reset. `updateTap()` brings it back.
    func stop() {
        guard let tap = ctx.tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        if let rl = ctx.runLoop { CFRunLoopStop(rl) }
        ctx.tap = nil; ctx.runLoop = nil
        log.notice("button remap: stopped")
    }

    private func start() {
        let mask = (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue)
            | (1 << CGEventType.otherMouseDragged.rawValue)
        let refcon = Unmanaged.passUnretained(ctx).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: tapCallback, userInfo: refcon)
        else { log.error("button remap: event tap could not be created"); return }
        nonisolated(unsafe) let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) // used only by the tap thread
        let ctx = ctx
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            ctx.runLoop = CFRunLoopGetCurrent()
            ready.signal()
            CFRunLoopRun() // returns when the tap is invalidated in stop()
        }
        thread.name = "MouseR event tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        ctx.tap = tap
        CGEvent.tapEnable(tap: tap, enable: true)
        log.notice("button remap: active")
    }

    private func perform(_ action: ButtonAction, isDown: Bool) {
        switch action {
        case .dpiUp, .dpiDown, .dpiClutch: onDPIAction?(action, isDown)
        case .back where isDown: navigate(.back)
        case .forward where isDown: navigate(.forward)
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

/// Runs on the tap thread. Must return fast: never does I/O or waits on the main thread.
private func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let ctx = Unmanaged<TapContext>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = ctx.tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
    guard let action = ctx.mapping[button], action != .standard else { return Unmanaged.passUnretained(event) }
    if type != .otherMouseDragged {
        let isDown = type == .otherMouseDown
        DispatchQueue.main.async { ctx.onAction?(action, isDown) }
    }
    return nil // swallow the original click
}
