import AppKit
import ApplicationServices
import CoreGraphics

/// Low-level Accessibility plumbing shared by every AX-touching component.
/// Pure functions over AXUIElement — no app state.
///
/// Every CF value read back from AX is type-checked before any cast, so a
/// misbehaving app returning an unexpected type degrades to nil/false instead
/// of undefined behavior.
enum AXHelpers {

    // MARK: - Reads

    /// The element's frame (position + size); nil when either attribute is
    /// unreadable or of an unexpected type.
    static func frame(of element: AXUIElement) -> CGRect? {
        guard let point = point(of: element), let size = size(of: element) else { return nil }
        return CGRect(origin: point, size: size)
    }

    /// Boolean attribute read that tolerates missing and mistyped values.
    static func bool(of element: AXUIElement, _ attribute: CFString) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success,
              let value = ref,
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return unsafeBitCast(value, to: CFBoolean.self) == kCFBooleanTrue
    }

    /// Casts a CF value to AXUIElement only after verifying its CF type.
    static func element(_ ref: CFTypeRef) -> AXUIElement? {
        guard CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(ref, to: AXUIElement.self)
    }

    /// The app element's window list, skipping entries that aren't AX elements.
    static func windowElements(of appElement: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &ref) == .success,
              let value = ref,
              CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        return (unsafeBitCast(value, to: NSArray.self) as? [AXUIElement]) ?? []
    }

    // MARK: - Writes

    static func set(position: CGPoint, on element: AXUIElement) {
        var point = position
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    static func set(size: CGSize, on element: AXUIElement) {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }

    static func setBool(_ bool: Bool, on element: AXUIElement, attribute: CFString) {
        AXUIElementSetAttributeValue(element, attribute, bool ? kCFBooleanTrue : kCFBooleanFalse)
    }

    // MARK: - Type-safe CF unwrapping

    private static func point(of element: AXUIElement) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &ref) == .success,
              let value = ref else { return nil }
        return pointValue(value)
    }

    private static func size(of element: AXUIElement) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &ref) == .success,
              let value = ref else { return nil }
        return sizeValue(value)
    }

    private static func pointValue(_ ref: CFTypeRef) -> CGPoint? {
        let value = axValue(ref, type: .cgPoint)
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private static func sizeValue(_ ref: CFTypeRef) -> CGSize? {
        let value = axValue(ref, type: .cgSize)
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }

    /// Casts a CF value to AXValue only after verifying it is one and carries
    /// the expected value type.
    private static func axValue(_ ref: CFTypeRef, type: AXValueType) -> AXValue {
        assert(CFGetTypeID(ref) == AXValueGetTypeID() && AXValueGetType(unsafeBitCast(ref, to: AXValue.self)) == type)
        return unsafeBitCast(ref, to: AXValue.self)
    }
}

/// Readable formatting for logs and the diagnostics dump.
enum Format {
    static func rect(_ r: CGRect) -> String {
        "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height)))"
    }

    static func appName(_ pid: pid_t) -> String {
        NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid:\(pid)"
    }
}
