import CoreGraphics

/// Modifier keys that can be held to dictate. Holding one alone types nothing.
enum ModifierKey: String, CaseIterable {
    case rightOption, rightCommand, rightControl, fn

    var keyCode: Int64 {
        switch self {
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        case .fn: return 63
        }
    }

    /// Device-specific flag bit, so the left-hand key of the same modifier doesn't trigger dictation.
    var flagBit: UInt64 {
        switch self {
        case .rightOption: return 0x40       // NX_DEVICERALTKEYMASK
        case .rightCommand: return 0x10      // NX_DEVICERCMDKEYMASK
        case .rightControl: return 0x2000    // NX_DEVICERCTLKEYMASK
        case .fn: return CGEventFlags.maskSecondaryFn.rawValue
        }
    }

    var title: String {
        switch self {
        case .rightOption: return "Right Option ⌥"
        case .rightCommand: return "Right Command ⌘"
        case .rightControl: return "Right Control ⌃"
        case .fn: return "fn / Globe 🌐"
        }
    }
}

/// What is held to dictate: a modifier key, or any mouse button other than left and right click.
enum Hotkey: Equatable, RawRepresentable {
    case key(ModifierKey)
    /// CGEvent button number: 2 is the middle button, 3 and 4 are usually Back and Forward.
    case mouseButton(Int64)

    private static let mousePrefix = "mouseButton"

    init?(rawValue: String) {
        if let key = ModifierKey(rawValue: rawValue) {
            self = .key(key)
        } else if rawValue.hasPrefix(Self.mousePrefix),
                  let number = Int64(rawValue.dropFirst(Self.mousePrefix.count)), number >= 2 {
            self = .mouseButton(number)
        } else {
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .key(let key): return key.rawValue
        case .mouseButton(let number): return "\(Self.mousePrefix)\(number)"
        }
    }

    var title: String {
        switch self {
        case .key(let key): return key.title
        case .mouseButton(2): return "Middle Mouse Button"
        case .mouseButton(3): return "Mouse Button 4 (Back)"
        case .mouseButton(4): return "Mouse Button 5 (Forward)"
        case .mouseButton(let number): return "Mouse Button \(number + 1)"
        }
    }
}

/// Watches the keyboard and mouse through a session-level CGEventTap and reports hold/release of the hotkey.
/// Keyboard events always pass through untouched. When the hotkey is a mouse button, that button's presses
/// are swallowed, so it doesn't also go Back in a browser or paste in a terminal.
final class HotkeyMonitor {
    var hotkey: Hotkey {
        didSet { isDown = false }
    }
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    /// Another key was pressed while the hotkey was held (e.g. Option+E for an accent): not a dictation.
    var onChord: () -> Void = {}

    private var tap: CFMachPort?
    private var isDown = false
    private var capture: ((Hotkey?) -> Void)?

    init(hotkey: Hotkey) {
        self.hotkey = hotkey
    }

    var isRunning: Bool { tap != nil }
    var isCapturing: Bool { capture != nil }

    /// Makes the next mouse-button press (other than left/right click) the hotkey and reports it.
    /// Pressing any key instead cancels, and reports nil.
    func captureMouseButton(_ completion: @escaping (Hotkey?) -> Void) {
        capture = completion
    }

    /// Returns false until the app has the Accessibility permission.
    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let mask = [CGEventType.flagsChanged, .keyDown, .otherMouseDown, .otherMouseUp]
            .reduce(CGEventMask(0)) { $0 | CGEventMask(1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                if let refcon, Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type, event) {
                    return nil
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        return true
    }

    /// Returns true when the event should be swallowed.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }

        case .flagsChanged:
            guard case .key(let key) = hotkey,
                  event.getIntegerValueField(.keyboardEventKeycode) == key.keyCode else { break }
            setDown(event.flags.rawValue & key.flagBit != 0)

        case .otherMouseDown, .otherMouseUp:
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            if type == .otherMouseDown, let capture {
                // Set it here rather than in the completion, so this press's mouse-up is swallowed too.
                let picked = Hotkey.mouseButton(button)
                hotkey = picked
                self.capture = nil
                DispatchQueue.main.async { capture(picked) }
                return true
            }
            guard hotkey == .mouseButton(button) else { break }
            setDown(type == .otherMouseDown)
            return true

        case .keyDown:
            guard event.getIntegerValueField(.eventSourceUserData) != TextInserter.eventMarker else { break }
            if let capture {
                self.capture = nil
                DispatchQueue.main.async { capture(nil) }
            } else if isDown {
                DispatchQueue.main.async { self.onChord() }
            }

        default:
            break
        }
        return false
    }

    private func setDown(_ down: Bool) {
        if down && !isDown {
            isDown = true
            DispatchQueue.main.async { self.onPress() }
        } else if !down && isDown {
            isDown = false
            DispatchQueue.main.async { self.onRelease() }
        }
    }
}
