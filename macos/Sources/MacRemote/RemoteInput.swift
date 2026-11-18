import AppKit
import CoreGraphics

struct RemoteCommand: Decodable {
    enum Kind: String, Decodable { case move, down, up, scroll, keyDown, keyUp, release, stream, frameAck }
    let type: Kind
    let x: Double?
    let y: Double?
    let button: Int?
    let dx: Double?
    let dy: Double?
    let code: String?
    let modifiers: UInt8?
    let codec: String?
    let frame: UInt64?
}

@MainActor
final class RemoteInput {
    private let displayID: CGDirectDisplayID
    private let source = CGEventSource(stateID: .privateState)
    private var lastPoint: CGPoint?
    private var buttons = [Int: Int64]()
    private var keys = Set<CGKeyCode>()
    private var lastClick: (button: Int, point: CGPoint, time: TimeInterval, count: Int64)?

    init(displayID: CGDirectDisplayID) { self.displayID = displayID }

    func apply(_ command: RemoteCommand) {
        var flags = CGEventFlags()
        let modifiers = command.modifiers ?? 0
        if modifiers & 1 != 0 { flags.insert(.maskShift) }
        if modifiers & 2 != 0 { flags.insert(.maskControl) }
        if modifiers & 4 != 0 { flags.insert(.maskAlternate) }
        if modifiers & 8 != 0 { flags.insert(.maskCommand) }

        switch command.type {
        case .move, .down, .up:
            guard let x = command.x, let y = command.y, (0...1).contains(x), (0...1).contains(y) else { return }
            let bounds = CGDisplayBounds(displayID)
            guard bounds.width > 0, bounds.height > 0 else { return }
            let point = CGPoint(x: bounds.minX + x * (bounds.width - 1), y: bounds.minY + y * (bounds.height - 1))
            lastPoint = point
            switch command.type {
            case .down:
                guard let button = command.button, (0...2).contains(button), buttons[button] == nil else { return }
                let time = ProcessInfo.processInfo.systemUptime
                var count: Int64 = 1
                if let lastClick, lastClick.button == button,
                   time - lastClick.time <= NSEvent.doubleClickInterval,
                   hypot(point.x - lastClick.point.x, point.y - lastClick.point.y) <= 4 {
                    count = lastClick.count % 3 + 1
                }
                lastClick = (button, point, time, count)
                buttons[button] = count
                mouse(button: button, type: [.leftMouseDown, .otherMouseDown, .rightMouseDown][button],
                      point: point, flags: flags, count: count)
            case .up:
                guard let button = command.button, let count = buttons.removeValue(forKey: button) else { return }
                mouse(button: button, type: [.leftMouseUp, .otherMouseUp, .rightMouseUp][button],
                      point: point, flags: flags, count: count)
            default:
                if let button = buttons.keys.min() {
                    mouse(button: button, type: [.leftMouseDragged, .otherMouseDragged, .rightMouseDragged][button],
                          point: point, flags: flags, count: buttons[button] ?? 1)
                } else {
                    mouse(button: 0, type: .mouseMoved, point: point, flags: flags, count: 0)
                }
            }
        case .scroll:
            let horizontal = Int32(-min(450, max(-450, command.dx ?? 0)))
            let vertical = Int32(-min(450, max(-450, command.dy ?? 0)))
            let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                                wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        case .keyDown, .keyUp:
            guard let code = command.code, let key = Self.keyCodes[code] else { return }
            let down = command.type == .keyDown
            let repeatKey = down && !keys.insert(key).inserted
            if !down && keys.remove(key) == nil { return }
            keyboard(key, down: down, flags: flags, repeatKey: repeatKey)
        case .release:
            release()
        case .stream, .frameAck:
            break
        }
    }

    func release() {
        if let lastPoint {
            for (button, count) in buttons {
                mouse(button: button, type: [.leftMouseUp, .otherMouseUp, .rightMouseUp][button],
                      point: lastPoint, flags: [], count: count)
            }
        }
        for key in keys { keyboard(key, down: false, flags: [], repeatKey: false) }
        buttons.removeAll()
        keys.removeAll()
        lastClick = nil
    }

    private func mouse(button: Int, type: CGEventType, point: CGPoint, flags: CGEventFlags, count: Int64) {
        let quartzButton: CGMouseButton = [.left, .center, .right][button]
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: quartzButton)
        event?.flags = flags
        event?.setIntegerValueField(.mouseEventClickState, value: count)
        event?.post(tap: .cghidEventTap)
    }

    private func keyboard(_ key: CGKeyCode, down: Bool, flags: CGEventFlags, repeatKey: Bool) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
        event?.flags = flags
        if repeatKey { event?.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        event?.post(tap: .cghidEventTap)
    }

    private static let keyCodes: [String: CGKeyCode] = [
        "KeyA": 0, "KeyS": 1, "KeyD": 2, "KeyF": 3, "KeyH": 4, "KeyG": 5, "KeyZ": 6, "KeyX": 7,
        "KeyC": 8, "KeyV": 9, "IntlBackslash": 10, "KeyB": 11, "KeyQ": 12, "KeyW": 13, "KeyE": 14,
        "KeyR": 15, "KeyY": 16, "KeyT": 17, "Digit1": 18, "Digit2": 19, "Digit3": 20, "Digit4": 21,
        "Digit6": 22, "Digit5": 23, "Equal": 24, "Digit9": 25, "Digit7": 26, "Minus": 27, "Digit8": 28,
        "Digit0": 29, "BracketRight": 30, "KeyO": 31, "KeyU": 32, "BracketLeft": 33, "KeyI": 34,
        "KeyP": 35, "Enter": 36, "KeyL": 37, "KeyJ": 38, "Quote": 39, "KeyK": 40, "Semicolon": 41,
        "Backslash": 42, "Comma": 43, "Slash": 44, "KeyN": 45, "KeyM": 46, "Period": 47, "Tab": 48,
        "Space": 49, "Backquote": 50, "Backspace": 51, "Escape": 53, "MetaRight": 54, "MetaLeft": 55,
        "ShiftLeft": 56, "CapsLock": 57, "AltLeft": 58, "ControlLeft": 59, "ShiftRight": 60,
        "AltRight": 61, "ControlRight": 62, "F17": 64, "NumpadDecimal": 65, "NumpadMultiply": 67,
        "NumpadAdd": 69, "NumLock": 71, "NumpadDivide": 75, "NumpadEnter": 76, "NumpadSubtract": 78,
        "F18": 79, "F19": 80, "NumpadEqual": 81, "Numpad0": 82, "Numpad1": 83, "Numpad2": 84,
        "Numpad3": 85, "Numpad4": 86, "Numpad5": 87, "Numpad6": 88, "Numpad7": 89, "F20": 90,
        "Numpad8": 91, "Numpad9": 92, "F5": 96, "F6": 97, "F7": 98, "F3": 99, "F8": 100,
        "F9": 101, "F11": 103, "F13": 105, "F16": 106, "F14": 107, "F10": 109, "F12": 111,
        "F15": 113, "Insert": 114, "Home": 115, "PageUp": 116, "Delete": 117, "F4": 118, "End": 119,
        "F2": 120, "PageDown": 121, "F1": 122, "ArrowLeft": 123, "ArrowRight": 124, "ArrowDown": 125,
        "ArrowUp": 126
    ]
}
