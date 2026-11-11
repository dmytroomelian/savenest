import AppKit
import Carbon
import SwiftUI

enum CaptureAction: String, CaseIterable, Identifiable {
    case quick, note, selected, window, search, duplicates, reader
    var id: String { rawValue }
    var title: String {
        switch self { case .quick: return "Save link"; case .note: return "Save with a note"; case .selected: return "Save selected tabs"; case .window: return "Save all tabs in window"; case .search: return "Open Savenest"; case .duplicates: return "Close duplicate tabs"; case .reader: return "Read & note current tab" }
    }
    var defaultShortcut: CaptureShortcut {
        if self == .reader { return .unassigned }
        if self == .search { return CaptureShortcut(keyCode: 31, modifiers: UInt32(cmdKey), character: "O") }
        if self == .duplicates { return CaptureShortcut(keyCode: 2, modifiers: UInt32(cmdKey | shiftKey), character: "D") }
        let modifiers: Int
        switch self {
        case .quick, .search, .duplicates, .reader: modifiers = cmdKey | shiftKey
        case .note: modifiers = cmdKey | optionKey
        case .selected: modifiers = cmdKey | shiftKey | controlKey
        case .window: modifiers = cmdKey | shiftKey | optionKey
        }
        return CaptureShortcut(keyCode: 40, modifiers: UInt32(modifiers), character: "K")
    }
    var hotkeyID: UInt32 { UInt32(Self.allCases.firstIndex(of: self)! + 1) }
    var memorableShortcut: CaptureShortcut {
        switch self {
        case .quick: return .init(keyCode: 40, modifiers: UInt32(cmdKey | shiftKey), character: "K")
        case .note: return .init(keyCode: 45, modifiers: UInt32(cmdKey | shiftKey), character: "N")
        default: return defaultShortcut
        }
    }
}

struct CaptureShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var character: String
    static let unassigned = CaptureShortcut(keyCode: UInt32.max, modifiers: 0, character: "")
    var isAssigned: Bool { keyCode != UInt32.max && modifiers != 0 && !character.isEmpty }
    static let standard = CaptureShortcut(keyCode: 40, modifiers: UInt32(cmdKey | shiftKey), character: "K")
    static let legacySearch = CaptureShortcut(keyCode: 31, modifiers: UInt32(cmdKey | shiftKey), character: "O")
    var label: String {
        guard isAssigned else { return "Not assigned" }
        return (modifiers & UInt32(controlKey) != 0 ? "⌃" : "") +
        (modifiers & UInt32(optionKey) != 0 ? "⌥" : "") +
        (modifiers & UInt32(shiftKey) != 0 ? "⇧" : "") +
        (modifiers & UInt32(cmdKey) != 0 ? "⌘" : "") + character
    }
    static func from(_ event: NSEvent) -> CaptureShortcut? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option),
              let chars = event.charactersIgnoringModifiers, !chars.isEmpty,
              ![36, 48, 51, 53, 76, 117].contains(Int(event.keyCode)),
              chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) else { return nil }
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        return .init(keyCode: UInt32(event.keyCode), modifiers: modifiers, character: chars == " " ? "Space" : chars.uppercased())
    }
}

final class GlobalShortcut {
    private var references: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    var action: ((CaptureAction) -> Void)?
    init() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer in
            guard let pointer, let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == 0x534E5354,
                  let captureAction = CaptureAction.allCases.first(where: { $0.hotkeyID == id.id }) else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<GlobalShortcut>.fromOpaque(pointer).takeUnretainedValue()
            DispatchQueue.main.async { owner.action?(captureAction) }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    @discardableResult func register(_ shortcuts: [CaptureAction: CaptureShortcut]) -> [CaptureAction] {
        unregister()
        var failed: [CaptureAction] = []
        for action in CaptureAction.allCases {
            guard let shortcut = shortcuts[action], shortcut.isAssigned else { continue }
            var reference: EventHotKeyRef?
            let id = EventHotKeyID(signature: 0x534E5354, id: action.hotkeyID)
            if RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &reference) == noErr, let reference {
                references.append(reference)
            } else { failed.append(action) }
        }
        return failed
    }
    func unregister() { for reference in references { UnregisterEventHotKey(reference) }; references = [] }
    deinit { unregister(); if let handler { RemoveEventHandler(handler) } }
}

struct ShortcutRecorder: NSViewRepresentable {
    let label: String
    let onStart: () -> Void
    let onRecord: (CaptureShortcut?) -> Void
    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton(); button.onStart = onStart; button.onRecord = onRecord
        button.title = label; button.bezelStyle = .rounded
        button.setAccessibilityLabel("Record capture keyboard shortcut")
        return button
    }
    func updateNSView(_ button: RecorderButton, context: Context) {
        button.currentLabel = label
        if !button.recording { button.title = label }
    }
}
final class RecorderButton: NSButton {
    var onStart: (() -> Void)?
    var onRecord: ((CaptureShortcut?) -> Void)?
    var currentLabel = ""
    var recording = false
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    override init(frame: NSRect) { super.init(frame: frame); target = self; action = #selector(start) }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func start() {
        if recording { finish(nil); return }
        recording = true; title = "Press shortcut…"; onStart?()
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in self?.finish(nil) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseDown { self.finish(nil); return event }
            if event.keyCode == 53 { self.finish(nil); return nil }
            if let shortcut = CaptureShortcut.from(event) { self.finish(shortcut) }
            else { self.title = "Use ⌘, ⌥, or ⌃ + a key" }
            return nil
        }
    }
    private func finish(_ shortcut: CaptureShortcut?) {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }; resignObserver = nil
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        recording = false; title = currentLabel; onRecord?(shortcut)
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) { if newWindow == nil && recording { finish(nil) }; super.viewWillMove(toWindow: newWindow) }
}
