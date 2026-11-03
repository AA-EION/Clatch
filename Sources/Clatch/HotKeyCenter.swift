// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import AppKit
import Carbon.HIToolbox
import ClatchCore

/// The global keyboard shortcut.
///
/// Uses Carbon's `RegisterEventHotKey`, which is still the supported way to
/// get a system-wide shortcut on macOS: it needs no Accessibility or Input
/// Monitoring permission, does not see any other keystroke, and costs nothing
/// until the key is pressed (the system delivers one event; there is no
/// polling or event tap).
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    enum Registration: Equatable {
        case off
        case active
        /// Another app registered the same shortcut first.
        case takenByAnotherApp
        /// The same keys are a macOS shortcut (System Settings › Keyboard › Keyboard Shortcuts).
        case conflictsWithSystem
    }

    var onPress: (() -> Void)?
    private(set) var registration: Registration = .off

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    nonisolated private static let signature: OSType = 0x434C_5443 // 'CLTC'

    private init() {}

    @discardableResult
    func register(_ combo: KeyCombo?) -> Registration {
        unregister()
        guard let combo else {
            registration = .off
            return registration
        }
        installHandlerIfNeeded()
        if Self.isSystemShortcut(combo) {
            registration = .conflictsWithSystem
            return registration
        }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers,
                                         EventHotKeyID(signature: Self.signature, id: 1),
                                         GetEventDispatcherTarget(), 0, &ref)
        if status == noErr, let ref {
            hotKeyRef = ref
            registration = .active
        } else {
            registration = .takenByAnotherApp
        }
        return registration
    }

    /// Temporarily releases the shortcut, e.g. while recording a new one.
    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == HotKeyCenter.signature else {
                return OSStatus(eventNotHandledErr)
            }
            // Carbon delivers hot key events on the main thread's event loop.
            MainActor.assumeIsolated {
                HotKeyCenter.shared.onPress?()
            }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }

    /// Whether macOS itself uses this combination (and has it switched on).
    static func isSystemShortcut(_ combo: KeyCombo) -> Bool {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let hotKeys = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return false }
        let relevant = KeyCombo.commandKey | KeyCombo.shiftKey | KeyCombo.optionKey | KeyCombo.controlKey
        for entry in hotKeys {
            guard (entry[kHISymbolicHotKeyEnabled as String] as? Bool) ?? false,
                  let code = (entry[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value,
                  let modifiers = (entry[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value
            else { continue }
            if code == combo.keyCode && (modifiers & relevant) == (combo.modifiers & relevant) {
                return true
            }
        }
        return false
    }

    /// Converts the parts of an AppKit key event into a shortcut.
    nonisolated static func combo(keyCode: UInt16, flags rawFlags: NSEvent.ModifierFlags,
                                  characters: String?) -> KeyCombo {
        let flags = rawFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= KeyCombo.commandKey }
        if flags.contains(.option) { modifiers |= KeyCombo.optionKey }
        if flags.contains(.control) { modifiers |= KeyCombo.controlKey }
        if flags.contains(.shift) { modifiers |= KeyCombo.shiftKey }
        let code = UInt32(keyCode)
        let label = KeyCombo.specialLabel(for: code)
            ?? characters?.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "?"
        return KeyCombo(keyCode: code, modifiers: modifiers, keyLabel: label.isEmpty ? "?" : label)
    }
}
