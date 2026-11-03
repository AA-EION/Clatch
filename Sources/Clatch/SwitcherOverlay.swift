// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group

import AppKit
import Carbon.HIToolbox
import ClatchCore
import SwiftUI

/// What the switcher shows.
@MainActor
final class SwitcherState: ObservableObject {
    struct Tile: Identifiable, Equatable {
        let id: UUID
        let account: Account
        let isCurrent: Bool
        let isRunning: Bool
    }

    @Published var tiles: [Tile] = []
    @Published var selection = 0
    @Published var sideBySide = false
    @Published var visible = false

    var selectedID: UUID? { tiles.indices.contains(selection) ? tiles[selection].id : nil }
}

/// The ⌘-Tab-style profile switcher.
///
/// The global shortcut opens it with the next profile highlighted; pressing
/// the shortcut again (Shift with it to go back, or ←/→ while holding the
/// modifiers) moves the highlight. Letting go of the modifiers opens the
/// highlighted profile; Esc cancels; Return opens it at once; a click works
/// too. While it is open Clatch reads the modifier keys' state (no
/// Accessibility permission needed, nothing is intercepted) and registers
/// the few extra shortcuts above; all of it stops when the switcher closes.
@MainActor
final class SwitcherOverlay {
    private let state = SwitcherState()
    private var panel: NSPanel?
    private var timer: Timer?
    private var combo: KeyCombo?
    private var shownAt = Date()
    /// Called with the chosen profile when the switcher closes on a choice.
    var onChoose: ((UUID) -> Void)?

    var isVisible: Bool { panel?.isVisible == true && state.visible }
    /// The switcher was opened again before the fade-out finished.
    private var isVisibleAfterReopen: Bool { state.visible }

    /// Opens the switcher, or moves the highlight if it is already open.
    func present(accounts: [Account], current: UUID?, running: Set<UUID>, sideBySide: Bool, combo: KeyCombo) {
        if isVisible {
            step(1)
            return
        }
        self.combo = combo
        state.sideBySide = sideBySide
        state.tiles = accounts.map {
            SwitcherState.Tile(id: $0.id, account: $0, isCurrent: $0.id == current, isRunning: running.contains($0.id))
        }
        let currentIndex = accounts.firstIndex { $0.id == current } ?? -1
        state.selection = accounts.isEmpty ? 0 : (currentIndex + 1) % accounts.count
        show()
        registerExtras()
        startWatchingModifiers()
    }

    func step(_ delta: Int) {
        guard !state.tiles.isEmpty else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            state.selection = (state.selection + delta + state.tiles.count) % state.tiles.count
        }
    }

    // MARK: - Window

    private func show() {
        let tileWidth: CGFloat = state.tiles.count > 7 ? 104 : 124
        let width = min(CGFloat(state.tiles.count) * tileWidth + 48, (screen()?.visibleFrame.width ?? 1200) - 80)
        let size = NSSize(width: max(width, 300), height: 216)
        let panel = self.panel ?? makePanel()
        let host = NSHostingView(rootView: SwitcherView(state: state, tileWidth: tileWidth) { [weak self] index in
            self?.state.selection = index
            self?.commit()
        })
        panel.contentView = host
        if let screen = screen() {
            let frame = screen.visibleFrame
            panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2 + frame.height * 0.08,
                                  width: size.width, height: size.height), display: false)
        }
        self.panel = panel
        shownAt = Date()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { state.visible = true }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func screen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    /// Closes the switcher; with `choose`, opens the highlighted profile.
    private func close(choose: Bool) {
        timer?.invalidate()
        timer = nil
        HotKeyCenter.shared.unregisterExtras()
        let chosen = choose ? state.selectedID : nil
        state.visible = false
        if let panel {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.isVisibleAfterReopen else { return }
                    self.panel?.orderOut(nil)
                    self.panel?.contentView = nil // release the view: nothing renders while closed
                }
            }
        }
        if let chosen { onChoose?(chosen) }
    }

    func commit() { close(choose: true) }
    func cancel() { close(choose: false) }

    // MARK: - Keys

    /// Extra shortcuts while open: back, ←, →, Esc, Return (all with the held modifiers).
    private func registerExtras() {
        guard let combo else { return }
        let held = combo.modifiers
        var extras = [
            KeyCombo(keyCode: combo.keyCode, modifiers: held | KeyCombo.shiftKey, keyLabel: combo.keyLabel),
            KeyCombo(keyCode: UInt32(kVK_LeftArrow), modifiers: held, keyLabel: "←"),
            KeyCombo(keyCode: UInt32(kVK_RightArrow), modifiers: held, keyLabel: "→"),
            KeyCombo(keyCode: UInt32(kVK_Escape), modifiers: held, keyLabel: "⎋"),
            KeyCombo(keyCode: UInt32(kVK_Return), modifiers: held, keyLabel: "↩"),
        ]
        if held & KeyCombo.shiftKey != 0 { extras[0] = extras[1] } // shortcut already uses Shift
        HotKeyCenter.shared.onExtraPress = { [weak self] index in
            switch index {
            case 0, 1: self?.step(-1)
            case 2: self?.step(1)
            case 3: self?.cancel()
            case 4: self?.commit()
            default: break
            }
        }
        HotKeyCenter.shared.registerExtras(extras)
    }

    /// Polls the modifier keys' state while open and commits when they are released.
    private func startWatchingModifiers() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkModifiers() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func checkModifiers() {
        guard let combo, isVisible else { return }
        let flags = NSEvent.modifierFlags
        var held = false
        if combo.modifiers & KeyCombo.commandKey != 0, flags.contains(.command) { held = true }
        if combo.modifiers & KeyCombo.optionKey != 0, flags.contains(.option) { held = true }
        if combo.modifiers & KeyCombo.controlKey != 0, flags.contains(.control) { held = true }
        if combo.modifiers & KeyCombo.shiftKey != 0, combo.modifiers & ~KeyCombo.shiftKey == 0, flags.contains(.shift) { held = true }
        if combo.modifiers == 0 {
            // A function key alone: wait until it is released.
            held = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(combo.keyCode))
        }
        // A tiny grace period so a very quick tap still shows the switcher briefly.
        if !held && Date().timeIntervalSince(shownAt) > 0.08 { commit() }
    }
}

// MARK: - View

private struct SwitcherView: View {
    @ObservedObject var state: SwitcherState
    let tileWidth: CGFloat
    let onPick: (Int) -> Void
    @Namespace private var highlight

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(Array(state.tiles.enumerated()), id: \.element.id) { index, tile in
                    tileView(tile, selected: index == state.selection)
                        .frame(width: tileWidth - 4)
                        .contentShape(Rectangle())
                        .onTapGesture { onPick(index) }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            Text(hint)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(NSColor.secondaryLabelColor))
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlayBackground()
        .scaleEffect(state.visible ? 1 : 0.94)
        .opacity(state.visible ? 1 : 0)
    }

    private var hint: String {
        let action = state.sideBySide ? "open" : "switch"
        return "Release to \(action) · Esc to cancel"
    }

    @ViewBuilder
    private func tileView(_ tile: SwitcherState.Tile, selected: Bool) -> some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: ProfileIcons.icon(for: tile.account, size: 84))
                    .resizable()
                    .frame(width: 72, height: 72)
                    .scaleEffect(selected ? 1.08 : 0.94)
                    .shadow(color: .black.opacity(selected ? 0.3 : 0.12), radius: selected ? 10 : 4, y: 3)
                if tile.isRunning && state.sideBySide {
                    Circle().fill(Color.green).frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                        .offset(x: 2, y: -2)
                }
            }
            HStack(spacing: 3) {
                if tile.isCurrent && !state.sideBySide {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundColor(.accentColor)
                }
                Text(tile.account.name)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundColor(Color(NSColor.labelColor))
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 6)
        .background(
            ZStack {
                if selected {
                    highlightShape(tile.account)
                        .matchedGeometryEffect(id: "highlight", in: highlight)
                }
            }
        )
    }

    @ViewBuilder
    private func highlightShape(_ account: Account) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        let tint = Color(ProfileIcons.color(for: account))
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            shape.fill(Color.clear)
                .glassEffect(Glass.regular.tint(tint.opacity(0.35)).interactive(), in: shape)
        } else {
            shape.fill(tint.opacity(0.22)).overlay(shape.stroke(tint.opacity(0.45), lineWidth: 1))
        }
        #else
        shape.fill(tint.opacity(0.22)).overlay(shape.stroke(tint.opacity(0.45), lineWidth: 1))
        #endif
    }
}

private extension View {
    /// Liquid Glass on macOS 26+, a HUD material before.
    @ViewBuilder
    func overlayBackground() -> some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 8) {
                self.glassEffect(.regular, in: shape)
            }
        } else {
            self.background(HUDMaterial().clipShape(shape))
                .overlay(shape.stroke(Color.white.opacity(0.18), lineWidth: 1))
        }
        #else
        self.background(HUDMaterial().clipShape(shape))
            .overlay(shape.stroke(Color.white.opacity(0.18), lineWidth: 1))
        #endif
    }
}

/// NSVisualEffectView's HUD material, for macOS 11–15.
private struct HUDMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
