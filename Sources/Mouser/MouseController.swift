import AppKit
import IOKit.hid
import SwiftUI

struct LightState: Equatable {
    var effect: LightingEffect = .staticColor
    var color: Color = .green
    var brightness: Double = 100 // percent
}

@MainActor
final class MouseController: ObservableObject {
    // Device
    @Published private(set) var spec: DeviceSpec?
    @Published private(set) var firmware: String?
    @Published private(set) var unsupportedRazer = false
    @Published private(set) var battery: (percent: Int, charging: Bool)?
    // Sensitivity
    @Published var stages: [Int] = []
    @Published var activeStage = 0
    @Published var currentDPI: Int?
    @Published var pollingRate = 1000
    // Lighting, per zone
    @Published var lights: [Zone: LightState] = [:]
    // macOS
    @Published var systemSpeed: Double = SystemPointer.speed()
    // Buttons
    @Published var mapping: [Int: ButtonAction] = [:]
    @Published private(set) var accessibilityGranted = ButtonRemapper.isTrusted

    /// Slider limit: Fabio's preference caps DPI at 4000 (higher is unusable on a desktop), or the mouse's own max if lower.
    static let dpiCap = 4000
    var maxDPI: Int { min(spec?.maxDPI ?? Self.dpiCap, Self.dpiCap) }
    /// Lowest DPI that really works. DeathAdder V2 Mini accepts 100 but then runs faster (tested), 200 works.
    private static let minDPIOverride: [Int: Int] = [0x008C: 200]
    var minDPI: Int { spec.flatMap { Self.minDPIOverride[$0.productID] } ?? 100 }

    private var device: RazerDevice?
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private let remapper = ButtonRemapper()
    private var timer: Timer?
    private var ticks = 0
    private var clutchRestoreDPI: Int?

    init() {
        for b in MouseButton.allCases {
            let raw = UserDefaults.standard.string(forKey: b.defaultsKey) ?? ""
            mapping[b.rawValue] = ButtonAction(rawValue: raw) ?? .standard
        }
        remapper.mapping = mapping
        remapper.onDPIAction = { [weak self] action, down in self?.handleDPIButton(action, down: down) }

        // HID is only used to notice plug/unplug. Matching mouse-type interfaces and only listing them
        // (never opening) needs no Input Monitoring permission.
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: DeviceCatalog.vendorID,
                                                kIOHIDPrimaryUsagePageKey: kHIDPage_GenericDesktop,
                                                kIOHIDPrimaryUsageKey: kHIDUsage_GD_Mouse] as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, _ in
            guard let ctx else { return }
            let me = Unmanaged<MouseController>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.rescan() }
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, _ in
            guard let ctx else { return }
            let me = Unmanaged<MouseController>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.rescan() }
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        // Keep in sync with the hardware DPI button, System Settings, battery and the Accessibility grant.
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLive() }
        }
    }

    // MARK: Device discovery

    private func rescan() {
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        let pids = Set(devices.map { IOHIDDeviceGetProperty($0, kIOHIDProductIDKey as CFString) as? Int ?? 0 })
        let found = DeviceCatalog.all.first { pids.contains($0.productID) }

        unsupportedRazer = found == nil && !devices.isEmpty
        if found?.productID == device?.spec.productID { return }
        // Commands go over USB control transfers, which need no Input Monitoring permission.
        device = found.flatMap(RazerDevice.init(spec:))
        log.notice("connect \(found?.name ?? "none", privacy: .public) usb=\(self.device != nil)")
        spec = device?.spec
        loadFromDevice()
    }

    private func loadFromDevice() {
        firmware = nil; currentDPI = nil; stages = []; battery = nil; lights = [:]
        guard let d = device else { return }
        firmware = d.firmware()
        if let s = d.dpiStages() { stages = s.stages; activeStage = s.active }
        currentDPI = d.dpi()
        if let p = d.pollingRate() { pollingRate = p }
        battery = d.battery()
        for z in d.spec.zones {
            var state = savedLight(z.zone)
            if let b = d.brightness(z) { state.brightness = (Double(b) / 255 * 100).rounded() }
            if z.effects[state.effect] == nil, let first = LightingEffect.allCases.first(where: { z.effects[$0] != nil }) {
                state.effect = first
            }
            lights[z.zone] = state
        }
    }

    private func refreshLive() {
        ticks += 1
        let s = SystemPointer.speed()
        if abs(s - systemSpeed) > 0.001 { systemSpeed = s }
        if accessibilityGranted != ButtonRemapper.isTrusted {
            accessibilityGranted = ButtonRemapper.isTrusted
            remapper.updateTap()
        }
        guard let d = device, clutchRestoreDPI == nil else { return }
        if let st = d.dpiStages(), st.active != activeStage { activeStage = st.active }
        if let dpi = d.dpi(), dpi != currentDPI { currentDPI = dpi }
        if ticks % 20 == 0 { battery = d.battery() } // every ~30 s
    }

    // MARK: Writes

    func applySystemSpeed() { SystemPointer.setSpeed(systemSpeed) }

    /// Saves stages to the mouse and switches to the active one.
    func applyStages() {
        guard let d = device, !stages.isEmpty else { return }
        activeStage = min(activeStage, stages.count - 1)
        log.notice("write stages \(self.stages, privacy: .public) active=\(self.activeStage + 1)")
        d.setDPIStages(stages, active: activeStage)
        d.setDPI(stages[activeStage])
        currentDPI = stages[activeStage]
    }

    /// For mice without DPI stages.
    func applyDPI() {
        guard let dpi = currentDPI else { return }
        log.notice("write dpi \(dpi)")
        device?.setDPI(dpi)
    }

    func addStage() {
        guard stages.count < 5 else { return }
        stages.append(min((stages.last ?? 800) * 2, maxDPI))
        applyStages()
    }

    func removeStage(at i: Int) {
        guard stages.count > 1 else { return }
        stages.remove(at: i)
        if activeStage >= stages.count { activeStage = stages.count - 1 }
        applyStages()
    }

    func applyPollingRate() { device?.setPollingRate(pollingRate) }

    func applyLighting(_ zone: Zone) {
        guard let d = device, let z = d.spec.zones.first(where: { $0.zone == zone }), let state = lights[zone] else { return }
        log.notice("write light \(zone.rawValue, privacy: .public) \(state.effect.rawValue, privacy: .public)")
        d.setEffect(z, state.effect, color: rgb(state.color))
        saveLight(zone, state)
    }

    func applyBrightness(_ zone: Zone) {
        guard let d = device, let z = d.spec.zones.first(where: { $0.zone == zone }), let state = lights[zone] else { return }
        log.notice("write brightness \(zone.rawValue, privacy: .public) \(Int(state.brightness))%")
        d.setBrightness(z, Int(state.brightness / 100 * 255))
    }

    func setAction(_ action: ButtonAction, for button: MouseButton) {
        mapping[button.rawValue] = action
        UserDefaults.standard.set(action.rawValue, forKey: button.defaultsKey)
        remapper.mapping = mapping
    }

    func requestAccessibility() { ButtonRemapper.requestTrust() }

    private func handleDPIButton(_ action: ButtonAction, down: Bool) {
        guard let d = device else { return }
        switch action {
        case .dpiUp where down && !stages.isEmpty:
            activeStage = (activeStage + 1) % stages.count; applyStages()
        case .dpiDown where down && !stages.isEmpty:
            activeStage = (activeStage - 1 + stages.count) % stages.count; applyStages()
        case .dpiClutch:
            if down {
                clutchRestoreDPI = currentDPI ?? stages.first ?? 800
                d.setDPI(stages.min() ?? 400)
            } else if let restore = clutchRestoreDPI {
                d.setDPI(restore); clutchRestoreDPI = nil
            }
        default: break
        }
    }

    // MARK: Lighting memory
    // Mice can't report their current effect in a common way, so the last choice is remembered per mouse and zone.

    private func lightKey(_ zone: Zone) -> String { "light.\(spec?.productID ?? 0).\(zone.rawValue)" }

    private func savedLight(_ zone: Zone) -> LightState {
        var s = LightState()
        guard let dict = UserDefaults.standard.dictionary(forKey: lightKey(zone)) else { return s }
        if let e = (dict["effect"] as? String).flatMap(LightingEffect.init(rawValue:)) { s.effect = e }
        if let c = dict["rgb"] as? [Int], c.count == 3 {
            s.color = Color(red: Double(c[0]) / 255, green: Double(c[1]) / 255, blue: Double(c[2]) / 255)
        }
        return s
    }

    private func saveLight(_ zone: Zone, _ s: LightState) {
        let c = rgb(s.color)
        UserDefaults.standard.set(["effect": s.effect.rawValue, "rgb": [Int(c.r), Int(c.g), Int(c.b)]], forKey: lightKey(zone))
    }

    private func rgb(_ c: Color) -> RGB {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? .white
        return RGB(r: UInt8(n.redComponent * 255), g: UInt8(n.greenComponent * 255), b: UInt8(n.blueComponent * 255))
    }
}
