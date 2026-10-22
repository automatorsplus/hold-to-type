import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum InsertMethod: String, CaseIterable {
    case paste, type

    var title: String {
        switch self {
        case .paste: return "Pasting (fast; clipboard is restored)"
        case .type: return "Typing keystrokes (leaves clipboard alone)"
        }
    }
}

/// Puts text at the focused cursor of whatever app is frontmost.
/// Synthesized events need the Accessibility permission.
enum TextInserter {
    /// Stamped on every synthesized event so our own hotkey tap can ignore them.
    static let eventMarker: Int64 = 0x484F_4C44 // "HOLD"

    static func insert(_ text: String, method: InsertMethod) {
        let text = addingLeadingSpaceIfNeeded(text)
        switch method {
        case .paste: paste(text)
        case .type: type(text)
        }
    }

    // MARK: - Paste: clipboard + ⌘V, then put the user's clipboard back

    private static func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(of: pasteboard)

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // nspasteboard.org convention: clipboard managers skip transient/concealed entries.
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.writeObjects([item])
        let ourChange = pasteboard.changeCount

        postKeystroke(virtualKey: keyCodeForCommandV(), flags: .maskCommand)

        // The target app reads the pasteboard asynchronously, so wait before restoring.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard pasteboard.changeCount == ourChange else { return } // user copied something meanwhile
            restore(saved, to: pasteboard)
        }
    }

    private static func snapshot(of pasteboard: NSPasteboard) -> [[(NSPasteboard.PasteboardType, Data)]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    private static func restore(_ saved: [[(NSPasteboard.PasteboardType, Data)]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items = saved.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    /// The key that types "v" while ⌘ is held on the current keyboard layout, so paste also works
    /// on Dvorak, AZERTY, etc. Falls back to the US-layout V (kVK_ANSI_V = 9).
    static func keyCodeForCommandV() -> CGKeyCode {
        let fallback = CGKeyCode(kVK_ANSI_V)
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutProperty = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return fallback }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutProperty).takeUnretainedValue() as Data

        return layoutData.withUnsafeBytes { raw -> CGKeyCode in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return fallback }
            let commandHeld = UInt32((cmdKey >> 8) & 0xFF)
            for keyCode in 0..<128 {
                var deadKeyState: UInt32 = 0
                var characters = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDown), commandHeld,
                                            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                            &deadKeyState, characters.count, &length, &characters)
                if status == noErr, length == 1, characters[0] == UniChar(UInt8(ascii: "v")) {
                    return CGKeyCode(keyCode)
                }
            }
            return fallback
        }
    }

    private static func postKeystroke(virtualKey: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: isDown) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Type: unicode keyboard events, no clipboard involved

    private static func type(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        for chunk in utf16Chunks(text, maxUnits: 20) {
            for isDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown) else { continue }
                event.flags = []
                chunk.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
                event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
                event.post(tap: .cghidEventTap)
            }
            usleep(3000)
        }
    }

    /// Splits on Character boundaries so emoji and surrogate pairs are never cut in half.
    private static func utf16Chunks(_ text: String, maxUnits: Int) -> [[UniChar]] {
        var chunks: [[UniChar]] = []
        var current: [UniChar] = []
        for character in text {
            let units = Array(String(character).utf16)
            if current.count + units.count > maxUnits, !current.isEmpty {
                chunks.append(current)
                current = []
            }
            current.append(contentsOf: units)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    // MARK: - Spacing between consecutive dictations

    /// If the character just before the cursor is a letter or punctuation, prepend a space so
    /// back-to-back dictations don't run together. Falls back to no space when the focused
    /// app doesn't expose its text through Accessibility.
    private static func addingLeadingSpaceIfNeeded(_ text: String) -> String {
        guard let first = text.first, !first.isWhitespace, !",.;:!?)]}".contains(first),
              let previous = characterBeforeCursor(),
              !previous.isWhitespace, !"([{\"'“‘/-–—".contains(previous)
        else { return text }
        return " " + text
    }

    private static func characterBeforeCursor() -> Character? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.2)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else { return nil }
        let focused = focusedRef as! AXUIElement

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID()
        else { return nil }
        var selection = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &selection), selection.location > 0 else { return nil }

        var previousRange = CFRange(location: selection.location - 1, length: 1)
        guard let previousRangeValue = AXValueCreate(.cfRange, &previousRange) else { return nil }
        var stringRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            focused, kAXStringForRangeParameterizedAttribute as CFString, previousRangeValue, &stringRef) == .success,
              let previous = stringRef as? String
        else { return nil }
        return previous.last
    }
}
