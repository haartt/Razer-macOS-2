import Foundation
import IOKit.hid

/// macOS "Tracking speed" (System Settings → Mouse).
/// Saved in the global pref `com.apple.mouse.scaling` (0…3) and applied live through
/// the HID event system as fixed-point (value × 65536), the same way System Settings does.
enum SystemPointer {
    static let range: ClosedRange<Double> = 0...3
    private static let key = "com.apple.mouse.scaling" as CFString
    private static let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)

    static func speed() -> Double {
        let v = CFPreferencesCopyValue(key, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return (v as? NSNumber)?.doubleValue ?? 1
    }

    static func setSpeed(_ value: Double) {
        CFPreferencesSetValue(key, value as CFNumber, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        IOHIDEventSystemClientSetProperty(client, kIOHIDMouseAccelerationType as CFString, Int(value * 65536) as CFNumber)
    }
}
