// Razer HID protocol. Packet layouts follow openrazer (GPL-2.0-or-later),
// https://github.com/openrazer/openrazer — driver/razerchromacommon.c
import Foundation
import os
import RazerUSB

let log = Logger(subsystem: "local.mouser.app", category: "mouse")

// MARK: - Device description (table in DeviceTable.swift, generated from openrazer)

/// Packet style used for lighting / brightness commands.
enum LightFamily {
    case extended       // class 0x0F, most mice since ~2018
    case mouseExtended  // class 0x03 cmd 0x0D (Naga Chroma, Naga Hex V2)
    case standardMatrix // class 0x03 cmd 0x0A, whole device, no LED id
    case standardLED    // class 0x03 cmd 0x00-0x03, older single LEDs
}

enum Zone: String, CaseIterable, Identifiable {
    case matrix, logo, scroll, left, right, backlight
    var id: String { rawValue }
    var title: String {
        switch self {
        case .matrix: "Lighting"
        case .logo: "Logo Lighting"
        case .scroll: "Scroll Wheel Lighting"
        case .left: "Left Side Lighting"
        case .right: "Right Side Lighting"
        case .backlight: "Backlight"
        }
    }
}

enum LightingEffect: String, CaseIterable, Identifiable {
    case off = "Off", staticColor = "Static", breathing = "Breathing", spectrum = "Spectrum"
    var id: String { rawValue }
    var usesColor: Bool { self == .staticColor || self == .breathing }
}

struct LightCmd {
    let family: LightFamily
    let tid: UInt8
    let led: UInt8
}

struct ZoneSpec {
    let zone: Zone
    let effects: [LightingEffect: LightCmd]
    let brightness: LightCmd?
}

struct DPICmd {
    let byteFormat: Bool // old mice: one byte = DPI / maxDPI * 255
    let tid: UInt8
}

struct PollCmd {
    let hyper: Bool       // HyperPolling (up to 8000 Hz) command set
    let tid: UInt8
    let secondTID: UInt8? // some HyperPolling mice need a second send with argument 0x01
    let rates: [Int]
}

struct DeviceSpec {
    let productID: Int
    let name: String
    let maxDPI: Int
    let tested: Bool
    let firmwareTID: UInt8
    let dpi: DPICmd?
    let stagesTID: UInt8?
    let poll: PollCmd?
    let batteryTID: UInt8?
    let chargingTID: UInt8?
    let zones: [ZoneSpec]
}

enum DeviceCatalog {
    static let vendorID = 0x1532
    static func spec(for pid: Int) -> DeviceSpec? { all.first { $0.productID == pid } }
}

struct RGB: Equatable { var r: UInt8, g: UInt8, b: UInt8 }

// MARK: - Device

/// 90-byte report: [0] status, [1] transaction id, [5] data size, [6] class, [7] command, [8..<88] args, [88] XOR checksum.
final class RazerDevice {
    let spec: DeviceSpec
    private let usb: OpaquePointer
    private let varStore: UInt8 = 0x01 // save to mouse memory

    init?(spec: DeviceSpec) {
        guard let usb = razer_usb_open(Int32(DeviceCatalog.vendorID), Int32(spec.productID)) else { return nil }
        self.usb = usb
        self.spec = spec
    }

    deinit { razer_usb_close(usb) }

    @discardableResult
    private func send(_ cls: UInt8, _ cmd: UInt8, size: UInt8, tid: UInt8, _ args: [UInt8] = []) -> [UInt8]? {
        var r = [UInt8](repeating: 0, count: 90)
        r[1] = tid; r[5] = size; r[6] = cls; r[7] = cmd
        for (i, a) in args.prefix(80).enumerated() { r[8 + i] = a }
        r[88] = r[2..<88].reduce(0, ^)
        let name = String(format: "cls=%02X cmd=%02X tid=%02X", cls, cmd, tid)
        let setResult = razer_usb_set_report(usb, r)
        guard setResult == 0 else {
            log.error("\(name, privacy: .public) send failed \(String(format: "0x%X", setResult), privacy: .public)")
            return nil
        }
        // Status: 0x01 busy, 0x02 success, 0x03 failure, 0x04 timeout, 0x05 not supported.
        var resp = [UInt8](repeating: 0, count: 90)
        for _ in 0..<10 {
            usleep(30_000)
            guard razer_usb_get_report(usb, &resp) == 0 else { continue }
            if resp[0] == 0x01 { continue }
            break
        }
        let ok = (resp[0] == 0x02 || resp[0] == 0x01) && resp[6] == cls && resp[7] == cmd
        if !ok { log.error("\(name, privacy: .public) status=\(resp[0])") }
        return ok ? Array(resp[8..<88]) : nil
    }

    // MARK: Info

    func firmware() -> String? {
        guard let a = send(0x00, 0x81, size: 0x02, tid: spec.firmwareTID) else { return nil }
        return "\(a[0]).\(a[1])"
    }

    func battery() -> (percent: Int, charging: Bool)? {
        guard let tid = spec.batteryTID, let a = send(0x07, 0x80, size: 0x02, tid: tid) else { return nil }
        var charging = false
        if let ctid = spec.chargingTID, let c = send(0x07, 0x84, size: 0x02, tid: ctid) { charging = c[1] == 1 }
        return (Int((Double(a[1]) / 255 * 100).rounded()), charging)
    }

    // MARK: DPI

    func dpi() -> Int? {
        guard let c = spec.dpi else { return nil }
        if c.byteFormat {
            guard let a = send(0x04, 0x81, size: 0x03, tid: c.tid) else { return nil }
            return Int((Double(a[0]) / 255 * Double(spec.maxDPI)).rounded())
        }
        guard let a = send(0x04, 0x85, size: 0x07, tid: c.tid, [varStore]) else { return nil }
        return Int(a[1]) << 8 | Int(a[2])
    }

    func setDPI(_ dpi: Int) {
        guard let c = spec.dpi else { return }
        if c.byteFormat {
            let b = UInt8(clamping: Int((Double(dpi) / Double(spec.maxDPI) * 255).rounded()))
            send(0x04, 0x01, size: 0x03, tid: c.tid, [b, b, 0])
            return
        }
        let v = UInt16(clamping: min(max(dpi, 100), 50000))
        send(0x04, 0x05, size: 0x07, tid: c.tid, [varStore, UInt8(v >> 8), UInt8(v & 0xFF), UInt8(v >> 8), UInt8(v & 0xFF), 0, 0])
    }

    /// (active stage 0-based, stage DPI values)
    func dpiStages() -> (active: Int, stages: [Int])? {
        guard let tid = spec.stagesTID, let a = send(0x04, 0x86, size: 0x26, tid: tid, [varStore]) else { return nil }
        let count = min(Int(a[2]), 5)
        let stages = (0..<count).map { i -> Int in let o = 3 + i * 7; return Int(a[o + 1]) << 8 | Int(a[o + 2]) }
        return (max(Int(a[1]) - 1, 0), stages)
    }

    func setDPIStages(_ stages: [Int], active: Int) {
        guard let tid = spec.stagesTID else { return }
        var args: [UInt8] = [varStore, UInt8(active + 1), UInt8(stages.count)] // active stage is 1-based
        for (i, dpi) in stages.enumerated() {
            let v = UInt16(clamping: dpi)
            args += [UInt8(i), UInt8(v >> 8), UInt8(v & 0xFF), UInt8(v >> 8), UInt8(v & 0xFF), 0, 0]
        }
        send(0x04, 0x06, size: 0x26, tid: tid, args)
    }

    // MARK: Polling rate

    private static let standardCodes: [Int: UInt8] = [1000: 0x01, 500: 0x02, 125: 0x08]
    private static let hyperCodes: [Int: UInt8] = [8000: 0x01, 4000: 0x02, 2000: 0x04, 1000: 0x08, 500: 0x10, 250: 0x20, 125: 0x40]

    func pollingRate() -> Int? {
        guard let c = spec.poll else { return nil }
        if c.hyper {
            guard let a = send(0x00, 0xC0, size: 0x01, tid: c.tid) else { return nil }
            return Self.hyperCodes.first { $0.value == a[1] }?.key
        }
        guard let a = send(0x00, 0x85, size: 0x01, tid: c.tid) else { return nil }
        return Self.standardCodes.first { $0.value == a[0] }?.key
    }

    func setPollingRate(_ hz: Int) {
        guard let c = spec.poll else { return }
        if c.hyper {
            let code = Self.hyperCodes[hz] ?? 0x10
            send(0x00, 0x40, size: 0x02, tid: c.tid, [0x00, code])
            if let second = c.secondTID { send(0x00, 0x40, size: 0x02, tid: second, [0x01, code]) }
        } else {
            send(0x00, 0x05, size: 0x01, tid: c.tid, [Self.standardCodes[hz] ?? 0x02])
        }
    }

    // MARK: Lighting

    func brightness(_ zone: ZoneSpec) -> Int? {
        guard let c = zone.brightness else { return nil }
        let a: [UInt8]?
        switch c.family {
        case .standardLED: a = send(0x03, 0x83, size: 0x03, tid: c.tid, [varStore, c.led])
        default: a = send(0x0F, 0x84, size: 0x03, tid: c.tid, [varStore, c.led])
        }
        return a.map { Int($0[2]) }
    }

    func setBrightness(_ zone: ZoneSpec, _ value: Int) {
        guard let c = zone.brightness else { return }
        let v = UInt8(clamping: value)
        switch c.family {
        case .standardLED: send(0x03, 0x03, size: 0x03, tid: c.tid, [varStore, c.led, v])
        default: send(0x0F, 0x04, size: 0x03, tid: c.tid, [varStore, c.led, v])
        }
    }

    func setEffect(_ zone: ZoneSpec, _ effect: LightingEffect, color: RGB) {
        guard let c = zone.effects[effect] else { return }
        let (r, g, b, t, led) = (color.r, color.g, color.b, c.tid, c.led)
        switch c.family {
        case .extended:
            switch effect {
            case .off: send(0x0F, 0x02, size: 0x06, tid: t, [varStore, led, 0x00, 0, 0, 0])
            case .staticColor: send(0x0F, 0x02, size: 0x09, tid: t, [varStore, led, 0x01, 0, 0, 0x01, r, g, b])
            case .breathing: send(0x0F, 0x02, size: 0x09, tid: t, [varStore, led, 0x02, 0x01, 0, 0x01, r, g, b])
            case .spectrum: send(0x0F, 0x02, size: 0x06, tid: t, [varStore, led, 0x03, 0, 0, 0])
            }
        case .mouseExtended:
            switch effect {
            case .off: send(0x03, 0x0D, size: 0x03, tid: t, [varStore, led, 0x00])
            case .staticColor: send(0x03, 0x0D, size: 0x06, tid: t, [varStore, led, 0x06, r, g, b])
            case .breathing: send(0x03, 0x0D, size: 0x0A, tid: t, [varStore, led, 0x03, 0x01, r, g, b])
            case .spectrum: send(0x03, 0x0D, size: 0x03, tid: t, [varStore, led, 0x04])
            }
        case .standardMatrix:
            switch effect {
            case .off: send(0x03, 0x0A, size: 0x01, tid: t, [0x00])
            case .staticColor: send(0x03, 0x0A, size: 0x04, tid: t, [0x06, r, g, b])
            case .breathing: send(0x03, 0x0A, size: 0x08, tid: t, [0x03, 0x01, r, g, b])
            case .spectrum: send(0x03, 0x0A, size: 0x01, tid: t, [0x04])
            }
        case .standardLED:
            // LED on/off, then color, then effect (0x00 static, 0x02 breathing, 0x04 spectrum)
            send(0x03, 0x00, size: 0x03, tid: t, [varStore, led, effect == .off ? 0 : 1])
            guard effect != .off else { return }
            if effect.usesColor { send(0x03, 0x01, size: 0x05, tid: t, [varStore, led, r, g, b]) }
            let code: UInt8 = switch effect { case .breathing: 0x02; case .spectrum: 0x04; default: 0x00 }
            send(0x03, 0x02, size: 0x03, tid: t, [varStore, led, code])
        }
    }
}
