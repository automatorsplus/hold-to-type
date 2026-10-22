import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum State: Equatable {
        case loading, ready, recording, transcribing
        case failed(String)
    }

    private var statusItem: NSStatusItem!
    private let transcriber = Transcriber()
    private let recorder = AudioRecorder()
    private let hud = HUD()
    private let hotkeys = HotkeyMonitor(hotkey: Settings.hotkey)
    private var permissionTimer: Timer?
    private var recordingStartedAt = Date()

    private var state: State = .loading {
        didSet { refreshUI() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        hotkeys.onPress = { [weak self] in self?.hotkeyPressed() }
        hotkeys.onRelease = { [weak self] in self?.hotkeyReleased() }
        hotkeys.onChord = { [weak self] in self?.cancelRecording() }

        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        startHotkeyMonitorWhenTrusted()
        loadModel()
        refreshUI()
    }

    // MARK: - Setup

    private func loadModel() {
        let path = Settings.modelPath
        transcriber.queue.async { [weak self] in
            do {
                try self?.transcriber.load(modelPath: path)
                DispatchQueue.main.async { self?.state = .ready }
            } catch {
                DispatchQueue.main.async { self?.state = .failed(error.localizedDescription) }
            }
        }
    }

    /// The event tap can only be created once Accessibility is granted, so keep retrying until it is.
    private func startHotkeyMonitorWhenTrusted() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options), hotkeys.start() {
            refreshUI()
            return
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self, AXIsProcessTrusted(), self.hotkeys.start() else { return }
            timer.invalidate()
            self.refreshUI()
        }
    }

    // MARK: - Dictation flow

    private func hotkeyPressed() {
        guard state == .ready else { return }
        // Play the cue before opening the mic so it mostly isn't captured.
        playSound("Tink")
        do {
            try recorder.start()
        } catch {
            hud.flash("Microphone unavailable")
            return
        }
        recordingStartedAt = Date()
        state = .recording
    }

    private func cancelRecording() {
        guard state == .recording else { return }
        _ = recorder.stop()
        state = .ready
    }

    private func hotkeyReleased() {
        guard state == .recording else { return }
        let heldFor = Date().timeIntervalSince(recordingStartedAt)
        if heldFor < 0.3 {
            // A quick tap, not a dictation.
            cancelRecording()
            return
        }
        state = .transcribing
        // Keep the mic open a beat longer: people tend to let go while finishing the last word.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.finishRecording()
        }
    }

    private func finishRecording() {
        let (raw, rate) = recorder.stop()
        playSound("Pop")
        let language = Settings.language
        let vocabulary = Settings.vocabulary
        let method = Settings.insertMethod

        transcriber.queue.async { [weak self] in
            guard let self else { return }
            let audio = AudioRecorder.resampleTo16k(raw, from: rate)
            var text = ""
            if AudioRecorder.containsSpeech(audio) {
                text = (try? self.transcriber.transcribe(samples: audio, language: language, prompt: vocabulary)) ?? ""
            }
            DispatchQueue.main.async {
                if !text.isEmpty { TextInserter.insert(text, method: method) }
                self.state = .ready
            }
        }
    }

    private func playSound(_ name: String) {
        guard let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = 0.25
        sound.play()
    }

    // MARK: - UI

    private func refreshUI() {
        guard let button = statusItem?.button else { return }
        let symbol: String
        var tint: NSColor?
        switch state {
        case .loading: symbol = "hourglass"
        case .ready: symbol = hotkeys.isRunning ? "mic" : "mic.slash"
        case .recording: symbol = "mic.fill"; tint = .systemRed
        case .transcribing: symbol = "waveform"
        case .failed: symbol = "exclamationmark.triangle"
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "HoldToType")
        button.contentTintColor = tint

        switch state {
        case .recording: hud.show("Listening…", dotColor: .systemRed)
        case .transcribing: hud.show("Transcribing…", dotColor: .systemOrange)
        default:
            if hotkeys.isCapturing {
                hud.show("Press a mouse button… (any key cancels)", dotColor: .systemBlue)
            } else {
                hud.hide()
            }
        }

        statusItem.menu = buildMenu()
    }

    private func setHotkey(_ hotkey: Hotkey) {
        Settings.hotkey = hotkey
        hotkeys.hotkey = hotkey
        refreshUI()
    }

    private func captureMouseButton() {
        guard hotkeys.isRunning else {
            hud.flash("Needs Accessibility permission")
            return
        }
        hotkeys.captureMouseButton { [weak self] picked in
            guard let self else { return }
            if let picked { Settings.hotkey = picked }
            self.refreshUI()
            if let picked { self.hud.flash("Hold \(picked.title) to dictate", dotColor: .systemGreen) }
        }
        refreshUI()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let statusText: String
        switch state {
        case .loading: statusText = "Loading Whisper model…"
        case .failed(let message): statusText = message
        default:
            statusText = hotkeys.isRunning
                ? "Hold \(Settings.hotkey.title) to dictate"
                : "Needs Accessibility permission"
        }
        menu.addItem(NSMenuItem(title: statusText, action: nil, keyEquivalent: ""))
        menu.addItem(.separator())

        var hotkeyItems = ModifierKey.allCases.map { key in
            item(key.title, checked: Settings.hotkey == .key(key)) { [weak self] in self?.setHotkey(.key(key)) }
        }
        hotkeyItems.append(.separator())
        if case .mouseButton = Settings.hotkey {
            hotkeyItems.append(item(Settings.hotkey.title, checked: true) {})
        }
        hotkeyItems.append(item("Set Mouse Button…") { [weak self] in self?.captureMouseButton() })
        menu.addItem(submenu("Hotkey", hotkeyItems))
        menu.addItem(submenu("Insert Text By", InsertMethod.allCases.map { method in
            item(method.title, checked: method == Settings.insertMethod) { [weak self] in
                Settings.insertMethod = method
                self?.refreshUI()
            }
        }))
        menu.addItem(submenu("Language", [("English", "en"), ("Detect automatically", "auto")].map { name, code in
            item(name, checked: code == Settings.language) { [weak self] in
                Settings.language = code
                self?.refreshUI()
            }
        }))

        menu.addItem(.separator())
        menu.addItem(item("Accessibility Settings…") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        })
        menu.addItem(item("Microphone Settings…") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        })
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit HoldToType", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu()
        items.forEach(menu.addItem)
        parent.submenu = menu
        return parent
    }

    private func item(_ title: String, checked: Bool = false, action: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, handler: action)
        item.state = checked ? .on : .off
        return item
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { handler() }
}

/// Small floating pill near the bottom of the screen. It never takes focus, so the
/// app you're dictating into stays frontmost and receives the paste.
final class HUD {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let dot = NSView()

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 170, height: 36),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let background = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        background.layer?.cornerRadius = 18

        dot.frame = NSRect(x: 16, y: 13, width: 10, height: 10)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.frame = NSRect(x: 34, y: 9, width: 126, height: 18)

        background.addSubview(dot)
        background.addSubview(label)
        panel.contentView = background
    }

    func show(_ text: String, dotColor: NSColor) {
        label.stringValue = text
        // Grow the pill for longer messages. The label sits 34 pt in, after the dot, with 10 pt to spare on the right.
        let labelWidth = max(126, ceil(label.intrinsicContentSize.width) + 6)
        panel.setContentSize(NSSize(width: labelWidth + 44, height: 36))
        label.frame.size.width = labelWidth
        dot.layer?.backgroundColor = dotColor.cgColor
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2, y: visible.minY + 60))
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func flash(_ text: String, dotColor: NSColor = .systemYellow) {
        show(text, dotColor: dotColor)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.hide() }
    }
}
